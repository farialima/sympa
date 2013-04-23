# SympaspoolClassic: this module contains methods to handle filesystem spools.
# RCS Identication ; $Revision: 6646 $ ; $Date: 2010-08-19 10:32:08 +0200 (jeu 19 aoû 2010) $ 
#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyrigh (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
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
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package SympaspoolClassic;

use strict;
use Exporter;
use File::Path qw(make_path remove_tree);
use Mail::Address;
use MIME::Base64;
use Sys::Hostname qw(hostname);
# tentative
use Data::Dumper;
use SDM;
use Message;
use List;

my ($dbh, $sth, $db_connected, @sth_stack, $use_db);
our $filename_regexp = '^(\S+)\.\d+\.\w+$';

## Creates an object.
sub new {
    Log::do_log('debug2', '(%s, %s, %s)', @_);
    my($pkg, $spoolname, $selection_status) = @_;
    my $spool = {};

    unless ($spoolname =~ /^(auth)|(bounce)|(digest)|(mod)|(msg)|(outgoing)|(automatic)|(subscribe)|(signoff)|(topic)|(task)$/){
	Log::do_log('err','internal error unknown spool %s',$spoolname);
	return undef;
    }
    $spool->{'spoolname'} = $spoolname;
    $spool->{'selection_status'} = $selection_status;
    my $queue = 'queue'.$spoolname;
    $queue = 'queue' if ($spoolname eq 'msg');
    $spool->{'dir'} = Site->$queue;
    if ($spool->{'selection_status'} and $spool->{'selection_status'} eq 'bad') {
	$spool->{'dir'} .= '/bad';
    }
    Log::do_log('trace','Spool to scan "%s"',$spool->{'dir'});
    bless $spool, $pkg;
    $spool->create_spool_dir;

    return $spool;
}

# total spool_table count : not object oriented, just a subroutine 
sub global_count {
    
    my $message_status = shift;
    Log::do_log('trace','%s',Sympa::Constants::SPOOLDIR);
    my @files = <Sympa::Constants::SPOOLDIR/*>;
    foreach my $file (@files) {
	log::do_log('trace','%s',$file);
    }
    my $count = @files;

    return $count;
}

sub count {
    my $self = shift;
    return ($self->get_content({'selection'=>'count'}));
}

#######################
#
#  get_content return the content an array of hash describing the spool content
# 
sub get_content {

    my $self = shift;
    my $data= shift;
    my $selector=$data->{'selector'};     # hash field->value used as filter  WHERE sql query 
    my $selection=$data->{'selection'};   # the list of field to select. possible values are :
                                          #    -  a comma separated list of field to select. 
                                          #    -  '*'  is the default .
                                          #    -  '*_but_message' mean any field except message which may be huge and unusefull while listing spools
                                          #    - 'count' mean the selection is just a count.
                                          # should be used mainly to select all but 'message' that may be huge and may be unusefull
    my $offset = $data->{'offset'};         # for pagination, start fetch at element number = $offset;
    my $page_size = $data->{'page_size'}; # for pagination, limit answers to $page_size
    my $orderby = $data->{'sortby'};      # sort
    my $way = $data->{'way'};             # asc or desc 
    

    my $sql_where = _sqlselector($selector);
    if ($self->{'selection_status'} eq 'bad') {
	$sql_where = $sql_where." AND message_status_spool = 'bad' " ;
    }else{
	$sql_where = $sql_where." AND message_status_spool <> 'bad' " ;
    }
    $sql_where =~s/^\s*AND//;

    my $statement ;
    if ($selection eq 'count'){
	# just return the selected count, not all the values
	$statement = 'SELECT COUNT(*) ';
    }else{
	$statement = 'SELECT '.&_selectfields($selection);
    }

    $statement = $statement . sprintf " FROM spool_table WHERE %s AND spoolname_spool = %s ",$sql_where,&SDM::quote($self->{'spoolname'});

    if ($orderby) {
	$statement = $statement. ' ORDER BY '.$orderby.'_spool ';
	$statement = $statement. ' DESC' if ($way eq 'desc') ;
    }
    if ($page_size) {
	$statement .= SDM::get_limit_clause(
	    {'offset' => $offset, 'rows_count' => $page_size}
	);
    }

    push @sth_stack, $sth;
    unless ($sth = &SDM::do_query($statement)) {
	$sth = pop @sth_stack;
	return undef;
    }
    if($selection eq 'count') {
	my @result = $sth->fetchrow_array();
	$sth->finish;
	$sth = pop @sth_stack;
	return $result[0];
    }else{
	my @messages;
	while (my $message = $sth->fetchrow_hashref('NAME_lc')) {
	    $message->{'date_asstring'} = &tools::epoch2yyyymmjj_hhmmss($message->{'date'});
	    $message->{'lockdate_asstring'} = &tools::epoch2yyyymmjj_hhmmss($message->{'lockdate'});
	    $message->{'messageasstring'} = MIME::Base64::decode($message->{'message'}) if ($message->{'message'}) ;
	    $message->{'listname'} = $message->{'list'}; # duplicated because "list" is a tt2 method that convert a string to an array of chars so you can't test  [% IF  message.list %] because it is always defined!!!
	    $message->{'status'} = $self->{'selection_status'}; 
	    push @messages, $message;

	    last if $page_size and $page_size <= scalar @messages;
	}
	$sth->finish();
	$sth = pop @sth_stack;
	return @messages;
    }
}

#######################
#
#  next : return next spool entry ordered by priority next lock the message_in_spool that is returned
#  returns 0 if no file found
#  returns undef if problem scanning spool
sub next {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    undef $self->{'current_file'};
    unless($self->refresh_spool_files_list) {
	Log::do_log('err','Unable to refresh spool %s files list',$self->get_id);
	return undef;
    }
    return 0 unless($#{$self->{'spool_files_list'}} > -1);
    $self->get_next_file_to_process;
    Log::do_log('trace','Will return file %s',$self->{'current_file'}{'name'});
    $self->{'current_file'}{'full_path'} = "$self->{'dir'}/$self->{'current_file'}{'name'}";
    $self->analyze_current_file_name;
    $self->get_current_file_priority;
    Log::do_log('trace','%s',$self->{'current_file'}{'list_object'});
    unless(defined $self->{'current_file'}{'messageasstring'}) {
	Log::do_log('err','Unable to gather content from file %s',$self->{'current_file'}{'full_path'});
	return undef;
    }
    return $self->{'current_file'};
}

sub get_next_file_to_process {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    foreach (@{$self->{'spool_files_list'}}) {
	$self->{'current_file'}{'name'} = $_;
	last if ($self->get_current_message_content);
    }
    return 1;
}

sub analyze_current_file_name {
    my $self = shift;
    Log::do_log('debug3','%s',$self->get_id);
    return undef unless($self->{'current_file'}{'name'} =~ /$filename_regexp/);
    ($self->{'current_file'}{'list'}, $self->{'current_file'}{'robot'}) = split(/\@/,$1);
    
    $self->{'current_file'}{'list'} = lc($self->{'current_file'}{'list'});
    $self->{'current_file'}{'robot'}=lc($self->{'current_file'}{'robot'});
    return undef unless ($self->{'current_file'}{'robot_object'} = Robot->new($self->{'current_file'}{'robot'}));

    my $list_check_regexp = $self->{'current_file'}{'robot_object'}->list_check_regexp;

    if ($self->{'current_file'}{'list'} =~ /^(\S+)-($list_check_regexp)$/) {
	($self->{'current_file'}{'list'}, $self->{'current_file'}{'type'}) = ($1, $2);
    }
    return 1;
}

sub get_current_file_priority {
    my $self = shift;
    Log::do_log('debug3','%s',$self->get_id);
    my $email = $self->{'current_file'}{'robot_object'}->email;
    
    if ($self->{'current_file'}{'list'} eq Site->listmaster_email) {
	## highest priority
	$self->{'current_file'}{'priority'} = 0;
    }elsif ($self->{'current_file'}{'type'} eq 'request') {
	$self->{'current_file'}{'priority'} = $self->{'current_file'}{'robot_object'}->request_priority;
    }elsif ($self->{'current_file'}{'type'} eq 'owner') {
	$self->{'current_file'}{'priority'} = $self->{'current_file'}{'robot_object'}->owner_priority;
    }elsif ($self->{'current_file'}{'list'} =~ /^(sympa|$email)(\@Site->host)?$/i) {	
	$self->{'current_file'}{'priority'} = $self->{'current_file'}{'robot_object'}->sympa_priority;
    }else {
	$self->{'current_file'}{'list_object'} =  List->new($self->{'current_file'}{'list'}, $self->{'current_file'}{'robot_object'}, {'just_try' => 1});
	if ($self->{'current_file'}{'list_object'} && $self->{'current_file'}{'list_object'}->isa('List')) {
	    $self->{'current_file'}{'priority'} = $self->{'current_file'}{'list_object'}->priority;
	}else {
	    $self->{'current_file'}{'priority'} = $self->{'current_file'}{'robot_object'}->default_list_priority;
	}
    }
    Log::do_log('trace','current file %s, priority %s',$self->{'current_file'}{'name'},$self->{'current_file'}{'priority'});
}

sub get_current_message_content {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    return undef unless($self->lock_current_message);
    my $spool_file_content;
    unless (open $spool_file_content, $self->{'dir'}.'/'.$self->{'current_file'}{'name'}) {
	Log::do_log('err','Unable to open file %s',$self->{'dir'}.'/'.$self->{'current_file'}{'name'});
	return undef;
    }
    local $/;
    $self->{'current_file'}{'messageasstring'} = <$spool_file_content>;
    close $spool_file_content;
    return 1;
}

sub lock_current_message {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    $self->{'current_file'}{'lock'} = new Lock($self->{'current_file'}{'name'});
    $self->{'current_file'}{'lock'}->set_timeout(-1);
    unless ($self->{'current_file'}{'lock'}->lock('write')) {
	Log::do_log('err','Unable to put a lock on file %s',$self->{'current_file'}{'name'});
	undef $self->{'current_file'}{'lock'};
	return undef;
    }
    return 1;
}

sub unlock_current_message {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    unless($self->{'current_file'}{'lock'} && $self->{'current_file'}{'lock'}->isa('Lock')) {
	undef$self->{'current_file'}{'lock'};
	return undef;
    }
    unless ($self->{'current_file'}{'lock'}->unlock()) {
	Log::do_log('err','Unable to remove lock from file %s',$self->{'current_file'}{'name'});
	undef $self->{'current_file'}{'lock'};
	return undef;
    }
    return 1;
}

sub get_files_in_spool {
    my $self = shift;
    return undef unless($self->refresh_spool_files_list);
    return @{$self->{'spool_files_list'}};
}

sub get_dirs_in_spool {
    my $self = shift;
    return undef unless($self->refresh_spool_dirs_list);
    return @{$self->{'spool_dirs_list'}};
}

sub refresh_spool_files_list {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    unless (-d $self->{'dir'}) {
	$self->create_spool_dir;
    }
    unless (opendir SPOOLDIR, $self->{'dir'}) {
	Log::do_log('err','Unable to access %s spool. Please check proper rights are set;',$self->{'dir'});
	return undef;
    }
    my @qfile = sort tools::by_date grep {!/^\./ && -f "$self->{'dir'}/$_"} readdir(SPOOLDIR);
    closedir(SPOOLDIR);
    $self->{'spool_files_list'} = \@qfile;
    return 1;
}

sub refresh_spool_dirs_list {
    my $self = shift;
    Log::do_log('debug2','%s',$self->get_id);
    unless (-d $self->{'dir'}) {
	$self->create_spool_dir;
    }
    unless (opendir SPOOLDIR, $self->{'dir'}) {
	Log::do_log('err','Unable to access %s spool. Please check proper rights are set;',$self->{'dir'});
	return undef;
    }
    my @qdir = sort tools::by_date grep {!/^(\.\.|\.)$/ && -d "$self->{'dir'}/$_"} readdir(SPOOLDIR);
    closedir(SPOOLDIR);
    $self->{'spool_dirs_list'} = \@qdir;
    return 1;
}

sub create_spool_dir {
    my $self = shift;
    Log::do_log('debug','%s',$self->get_id);
    unless (-d $self->{'dir'}) {
	make_path($self->{'dir'});
    }
}

sub move_current_file_to_bad {
    my $self = shift;
    Log::do_log('debug', 'Moving spooled entity %s to bad',$self->{'current_file'}{'name'});
    unless (-d $self->{'dir'}.'/bad') {
	make_path($self->{'dir'}.'/bad');
    }
    unless(File::Copy::copy($self->{'dir'}.'/'.$self->{'current_file'}{'name'}, $self->{'dir'}.'/bad/'.$self->{'current_file'}{'name'})) {
	Log::do_log('err','Could not move file %s to spool bad %s: %s',$self->{'dir'}.'/'.$self->{'current_file'}{'name'},$self->{'dir'}.'/bad',$!);
	return undef;
    }
    unless (unlink ($self->{'dir'}.'/'.$self->{'current_file'}{'name'})) {
	&Log::do_log('err',"Could not unlink message %s/%s . Exiting",$self->{'dir'}, $self->{'current_file'}{'name'});
    }
    $self->unlock_current_message;
    return 1;
}

#################"
# return one message from related spool using a specified selector
# returns undef if message was not found.
#  
sub get_message {
    my $self = shift;
    my $selector = shift;
    Log::do_log('debug2', '(%s, messagekey=%s, list=%s, robot=%s)',
	$self, $selector->{'messagekey'},
	$selector->{'list'}, $selector->{'robot'});

    my $sqlselector = _sqlselector($selector);
    my $all = _selectfields();

    push @sth_stack, $sth;

    unless ($sth = SDM::do_query(
	q{SELECT %s
	  FROM spool_table
	  WHERE spoolname_spool = %s%s
	  %s},
	$all, SDM::quote($self->{'spoolname'}),
	($sqlselector ? " AND $sqlselector" : ''),
	SDM::get_limit_clause({'rows_count' => 1})
    )) {
	Log::do_log('err',
	    'Could not get message from spool %s', $self);
	$sth = pop @sth_stack;
	return undef;
    }

    my $message = $sth->fetchrow_hashref('NAME_lc');

    $sth->finish;
    $sth = pop @sth_stack;

    return undef unless $message and %$message;

    $message->{'lock'} =  $message->{'messagelock'}; 
    $message->{'messageasstring'} =
	MIME::Base64::decode($message->{'message'});

    if ($message->{'list'} && $message->{'robot'}) {
	my $robot = Robot->new($message->{'robot'});
	if ($robot) {
	    my $list = List->new($message->{'list'}, $robot);
	    if ($list) {
		$message->{'list_object'} = $list;
	    }
	}
    }
    return $message;
}

#################"
# lock one message from related spool using a specified selector
#  
sub unlock_message {

    my $self = shift;
    my $messagekey = shift;

    &Log::do_log('debug', 'Spool::unlock_message(%s,%s)',$self->{'spoolname'}, $messagekey);
    return ( $self->update({'messagekey' => $messagekey},
			   {'messagelock' => 'NULL'}));
}

################"
# store a message in database spool 
#
sub store {  
    my $self = shift;
    my $messageasstring = shift;
    my $param = shift;
    my $target_file = $param->{'filename'};
    $target_file ||= $self->get_storage_name({'list'=>$param->{'list'}, 'robot'=>$param->{'robot'}});
    my $fh;
    unless(open $fh, ">", "$self->{'dir'}/$target_file") {
	Log::do_log('trace','');
	return undef;
    }
    print $fh, $messageasstring;
    close $fh;
    return 1;
}

sub get_storage_name {
    my $self = shift;
    my $filename;
    my $param = shift;
    if ($param->{'list'} && $param->{'robot'}) {
	$filename = $param->{'list'}.'@'.$param->{'robot'}.'.'.time.'.'.int(rand(10000));
    }
    return $filename;
}

################"
# remove a message in database spool using (messagekey,list,robot) which are a unique id in the spool
#
sub remove_current_message {  
    my $self = shift;
    unless (unlink $self->{'dir'}.'/'.$self->{'current_file'}{'name'}) {
	Log::do_log('err','Unable to remove file %s: %s',$self->{'dir'}.'/'.$self->{'current_file'}{'name'},$!);
	return undef;
    }
    return 1;
}


################"
# Clean a spool by removing old messages
#

sub clean {  
    my $self = shift;
    my $filter = shift;
    &Log::do_log('debug','Cleaning spool %s (%s), delay: %s',$self->{'spoolname'},$self->{'selection_status'},$filter->{'delay'});

    return undef unless $self->{'spoolname'};
    return undef unless $filter->{'delay'};
    
    my $freshness_date = time - ($filter->{'delay'} * 60 * 60 * 24);
    my $deleted = 0;

    my @to_kill = $self->get_files_in_spool;
    foreach my $f (@to_kill) {
	if ((stat "$self->{'dir'}/$f")[9] < $freshness_date) {
	    if (unlink ("$self->{'dir'}/$f") ) {
		$deleted++;
		Log::do_log('notice', 'Deleting old file %s', "$self->{'dir'}/$f");
	    }else{
		Log::do_log('notice', 'unable to delete old file %s: %s', "$self->{'dir'}/$f",$!);
	    }
	}else{
	    last;
	}
    }
    @to_kill = $self->get_dirs_in_spool;
    foreach my $d (@to_kill) {
	if ((stat "$self->{'dir'}/$d")[9] < $freshness_date) {
	    if (tools::remove_dir("$self->{'dir'}/$d") ) {
		$deleted++;
		Log::do_log('notice', 'Deleting old file %s', "$self->{'dir'}/$d");
	    }else{
		Log::do_log('notice', 'unable to delete old file %s: %s', "$self->{'dir'}/$d",$!);
	    }
	}else{
	    last;
	}
    }

    Log::do_log('debug',"%s entries older than %s days removed from spool %s" ,$deleted,$filter->{'delay'},$self->{'spoolname'});
    return 1;
}



## Get unique ID
sub get_id {
    my $self = shift;
    return sprintf '%s/%s', $self->{'spoolname'}, $self->{'selection_status'};
}

###### END of the Sympapool package ######

## Packages must return true.
1;