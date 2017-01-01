# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015, 2016, 2017 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Request::Handler::del;

use strict;
use warnings;
use Time::HiRes qw();

use Sympa;
use Conf;
use Sympa::Language;
use Sympa::Log;

use base qw(Sympa::Request::Handler);

my $language = Sympa::Language->instance;
my $log      = Sympa::Log->instance;

use constant _action_scenario => 'del';
use constant _action_regexp   => qr'reject|request_auth|do_it'i;
use constant _context_class   => 'Sympa::List';

# Old name: Sympa::Commands::del().
sub _twist {
    my $self    = shift;
    my $request = shift;

    my $list   = $request->{context};
    my $which  = $list->{'name'};
    my $robot  = $list->{'domain'};
    my $sender = $request->{sender};
    my $who    = $request->{email};

    $language->set_lang($list->{'admin'}{'lang'});

    # Check if we know this email on the list and remove it. Otherwise
    # just reject the message.
    my $user_entry = $list->get_list_member($who);

    unless (defined $user_entry) {
        $self->add_stash($request, 'user', 'user_not_subscriber');
        $log->syslog('info', 'DEL %s %s from %s refused, not on list',
            $which, $who, $sender);
        return undef;
    }

    # If a list is not 'open' and allow_subscribe_if_pending has been set to
    # 'off' returns undef.
    unless ($list->{'admin'}{'status'} eq 'open'
        or
        Conf::get_robot_conf($list->{'domain'}, 'allow_subscribe_if_pending')
        eq 'on') {
        $self->add_stash($request, 'user', 'list_not_open',
            {'status' => $list->{'admin'}{'status'}});
        $log->syslog('info', 'List %s not open', $list);
        return undef;
    }

    # Really delete and rewrite to disk.
    unless (
        $list->delete_list_member(
            'users'     => [$who],
            'exclude'   => ' 1',
            'operation' => 'del'
        )
        ) {
        my $error =
            "Unable to delete user $who from list $which for command 'del'";
        Sympa::send_notify_to_listmaster(
            $list,
            'mail_intern_error',
            {   error  => $error,
                who    => $sender,
                action => 'Command process',
            }
        );
        $self->add_stash($request, 'intern');
        return undef;
    }

    ## Send a notice to the removed user, unless the owner indicated
    ## quiet del.
    unless ($request->{quiet}) {
        unless (Sympa::send_file($list, 'removed', $who, {})) {
            $log->syslog('notice', 'Unable to send template "removed" to %s',
                $who);
        }
    }
    $self->add_stash($request, 'notice', 'removed', {'email' => $who});
    $log->syslog(
        'info',
        'DEL %s %s from %s accepted (%.2f seconds, %d subscribers)',
        $which,
        $who,
        $sender,
        Time::HiRes::time() - $self->{start_time},
        $list->get_total()
    );
    if ($request->{notify}) {
        $list->send_notify_to_owner(
            'notice',
            {   'who'     => $who,
                'gecos'   => "",
                'command' => 'del',
                'by'      => $sender
            }
        );
    }
    return 1;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Request::Handler::del - del request handler

=head1 DESCRIPTION

Removes a user from a list (requested by another user).
Verifies the authorization and sends acknowledgements
unless quiet is specified.

=head1 SEE ALSO

L<Sympa::Request::Handler>.

=head1 HISTORY

=cut
