package HTTP::Cache;

use strict;

our $VERSION = '1.1.99';

=head1 NAME

HTTP::Cache - Cache the result of http get-requests persistently.

=head1 SYNOPSIS

  use LWP::Simple;
  use HTTP::Cache;

  my $cache = HTTP::Cache->new();
  $cache->init( {
    BasePath => '/tmp/cache',
  } );

  my $ua = LWP::UserAgent->new();
  $cache->apply($ua);

  my $data = $ua->get( 'http://www.sn.no' );

  $cache->unapply($ua);

=head1 DESCRIPTION

An implementation of http get that keeps a local cache of fetched
pages to avoid fetching the same data from the server if it hasn't
been updated. The cache is stored on disk and is thus persistent
between invocations.

Uses the http-headers If-Modified-Since and ETag to let the server
decide if the version in the cache is up-to-date or not.

The cache is implemented by modifying individual LWP::UserAgent
objects to seamlessly cache the result of all requests that can be
cached.

=head1 INITIALIZING THE CACHE

HTTP::Cache provides an init-method that sets the
parameters for the cache and overloads a method in LWP::UserAgent
to activate the cache.After init has been called, the normal 
LWP-methods (LWP::Simple as well as the more full-fledged 
LWP::Request methods) should be used as usual.

=over 4

=cut

use Carp;
use LWP::UserAgent;
use HTTP::Status qw/RC_NOT_MODIFIED RC_OK RC_PARTIAL_CONTENT status_message/;
use HTTP::Date qw/str2time/;

use Digest::MD5 qw/md5_hex/;
use IO::File;
use File::Copy;
use File::Path;
use Cwd;

# These are the response-headers that we should store in the
# cache-entry and recreate when we return a cached response.
my @cache_headers = qw/Content-Type Content-Encoding
                       Content-Length Content-Range 
                       Last-Modified Date/;

my $org_simple_request;

=item init

Initialize the HTTP cache. Takes a single parameter which is a 
hashref containing named arguments to the object.

  $cache->init( { 

    # Directory to store the cache in. 
    BasePath  => "/tmp/cache", 

    # How many hours should items be kept in the cache 
    # after they were last requested?
    # Default is 8*24.
    MaxAge    => 8*24,         

    # Print progress-messages to STDERR. 
    # Default is 0.
    Verbose   => 1,
  
    # If a request is made for a url that has been requested 
    # from the server less than NoUpdate seconds ago, the 
    # response will be generated from the cache without
    # contacting the server.
    # Default is 0.
    NoUpdate  => 15*60,

    # If a resource is known to be updated every N seconds, and you
    # want to be able to fetch it as soon as the next version of it is
    # expected to be available instead of being forced to wait N
    # seconds after your recent cache request, set this flag.
    #
    # NOTE: EXERCISE CAUTION WHEN USING THIS OPTION.  CONSIDER ONLY
    # USING IT ON A SMALL SCALE.  BE RESPONSIBLE.  If a lot of clients
    # use this approach against a server, then they would all hit the
    # server at the time that the data feed is supposed to have been
    # updated. This could cause a spike in server load that the server
    # owner may want to avoid. However, on a small scale it might
    # work.
    #
    # Default is 0.
    NoUpdateImpatient => 1,

    # Extra time to give the server to update their resource.
    # Default is 2 seconds.
    NoUpdateImpatientFudgeFactor => 3,

    # When a url has been downloaded and the response indicates that
    # has been modified compared to the content in the cache, 
    # the ApproveContent callback is called with the HTTP::Response.
    # The callback shall return true if the response shall be used and
    # stored in the cache or false if the response shall be discarded
    # and the response in the cache used instead.
    # This mechanism can be used to work around servers that return errors
    # intermittently. The default is to accept all responses.
    ApproveContent => sub { return $_[0]->is_success },
 } );

The directory where the cache is stored must be writable. It must also only
contain files created by HTTP::Cache.

=cut

sub new {
  my ($class) = @_;
  my $self = bless({}, $class);
  $self->{initialized} = 0;
  return $self;
}

sub init {
  my ($self, $arg) = @_;

  defined( $arg->{BasePath} ) 
    or croak( "You must specify a BasePath" ); 

  $self->{basepath} = $arg->{BasePath};

  if( not -d $self->{basepath} ) {
    eval { mkpath($self->{basepath}) };
    if ($@) {
      print STDERR "$self->{basepath} is not a directory and cannot be created: $@\n";
      exit 1;
    }
  }

  # Append a trailing slash if it is missing.
  $self->{basepath} =~ s%([^/])$%$1/%;

  $self->{maxage} = $arg->{MaxAge} || 8*24; 
  $self->{verbose} = $arg->{Verbose} || 0;
  $self->{noupdate} = $arg->{NoUpdate} || 0;
  $self->{noupdateimpatient} = defined( $arg->{NoUpdateImpatient} )
    ? $arg->{NoUpdateImpatient} : 0;
  $self->{noupdateimpatientfudgefactor} = defined( $arg->{NoUpdateImpatientFudgeFactor} )
    ? $arg->{NoUpdateImpatientFudgeFactor} : 2;
  $self->{approvecontent} = $arg->{ApproveContent} || sub { return 1; };
  
  # Make sure that LWP::Simple does not use its simplified
  # get-method that bypasses LWP::UserAgent. 
  $LWP::Simple::FULL_LWP++;
}

sub apply {
  my ($self, @obj) = @_;
}
sub unapply {
  my ($self, @obj) = @_;
}

=item Initializing from use-line

An alternative way of initializing HTTP::Cache is to supply
parameters in the use-line. This allows you to write

  use HTTP::Cache ( BasePath => '/tmp/cache' );

which is exactly equivalent to

  use HTTP::Cache;
  HTTP::Cache::init( BasePath => '/tmp/cache' );

The advantage to using this method is that you can do

  perl -MHTTP::Cache=BasePath,/tmp/cache myscript.pl

or even set the environment variable PERL5OPT 
  
  PERL5OPT=-MHTTP::Cache=BasePath,/tmp/cache
  myscript.pl

and have all the http-requests performed by myscript.pl go through the
cache without changing myscript.pl

=back

=cut 

sub import {
  my( $module, %args ) = @_;
  return if (scalar(keys(%args)) == 0);

  HTTP::Cache::init( \%args );
}

sub DESTROY {
  my ($self) = @_;
  $self->_remove_old_entries();
}


sub _get_from_cachefile {
  my( $self, $filename, $fh, $res, $meta ) = @_;

  my $content;
  my $buf;
  while ( $fh->read( $buf, 1024 ) > 0 ) {
    $content .= $buf;
  }
  
  $fh->close();
  
  $content = "" if not defined $content;

  # Set last-accessed for cache-entry.
  my $mtime = time;
  utime( $mtime, $mtime, $filename );
  
  # modify response
  if( $HTTP::Message::VERSION >= 1.44 ) {
    $res->content_ref( \$content );
  }
  else {
    $res->content( $content );
  }
  
  # For HTTP::Cache earlier than 0.4,
  # there is no Code in the cache.
  if( defined( $meta->{Code} ) ) {
    $res->code( $meta->{Code} );
  }
  else {
    $res->code( RC_OK );
  }
  $res->message(status_message($res->code) || "Unknown code");
  
  foreach my $h (@cache_headers) {
    $res->header( $h, $meta->{$h} )
      if defined( $meta->{ $h } );
  }
  
  $res->header( "X-Cached", 1 );
  $res->header( "X-Content-Unchanged", 1 );
}

# Read metadata and position filehandle at start of data.
sub _read_meta {
  my( $self, $fh ) = @_;
  my %meta;

  my( $key, $value );
  do {
    my $line = <$fh>;
    ( $key, $value ) = ($line =~ /(\S+)\s+(.*)[\n\r]*/);

    $meta{$key} = $value
      if( defined $value );
  } while( defined( $value ) );

  return \%meta;
}

# Write metadata and position filehandle where data should be written.
sub _write_meta {
  my( $self, $fh, $meta ) = @_;

  foreach my $key (sort keys( %{$meta} ) ) {
    print $fh "$key $meta->{$key}\n";
  }
  
  print $fh "\n";
}

sub _write_cache_entry {
  my( $self, $filename, $url, $req, $res ) = @_;

  my $out_filename = "$filename.tmp$$";
  my $fh = new IO::File "> $out_filename"
    or die "Failed to write to $out_filename";

  my $meta;
  $meta->{Url} = $url;
  $meta->{ETag} = $res->header('ETag') 
    if defined( $res->header('ETag') );

  my $content = $res->content;
  $content = "" if not defined $content;

  my $client_time = time;

  $meta->{MD5} = md5_hex( $content );
  $meta->{Range} = $req->header('Range')
    if defined( $req->header('Range') );
  $meta->{Code} = $res->code;
  $meta->{'X-HCT-LastUpdated'} = $client_time;

  # for NoUpdateImpatient (we set these headers whether
  # NoUpdateImpatient is set or not, in case we turn it on later on.)
  my $server_time_str = $res->header('Date');
  my $server_last_modified_str = $res->header('Last-Modified');
  if (defined $server_time_str && $server_time_str &&
      defined $server_last_modified_str && $server_last_modified_str) {
    my $server_time = str2time($server_time_str);
    my $server_last_modified = str2time($server_last_modified_str);
    if (defined $server_time && $server_time &&
	defined $server_last_modified && $server_last_modified) {
      my $server_drift = $server_time - $client_time;
      # ^^^ $server_drift will be the number of seconds server time
      # is AHEAD of client time.  We update our copy of the resource
      # based on what the last modified time would be on the client.
      my $client_last_modified = $server_last_modified - $server_drift;
      $meta->{'X-HCT-LastModified'} = $client_last_modified;
    }
  }

  foreach my $h (@cache_headers) {
    $meta->{$h} = $res->header( $h )
      if defined $res->header( $h );
  }

  $self->_write_meta( $fh, $meta );

  print $fh $content;
  $fh->close;

  move( $out_filename, $filename ) || unlink $out_filename;
}

sub _urlhash {
  my( $self, $url ) = @_;

  return md5_hex( $url );
}

sub _remove_old_entries {
  my( $self ) = @_;

  if( defined( $self->{basepath} ) and -d( $self->{basepath} ) ) {
    my $oldcwd = getcwd();
    chdir( $self->{basepath} );

    my @files = glob("*");
    foreach my $file (@files) {
      if( $file !~ m%^[0-9a-f]{32}$% ) {
        print STDERR "HTTP::Cache: Unknown file found in cache directory: $self->{basepath}$file\n";
      }
      else {
	  my $age = (-M $file);
	  # The file may have disappeared if another process has cleaned
	  # the cache.
	  if( defined($age) && ( $age*24 > $self->{maxage} ) ) {
	      print STDERR "Deleting $file.\n"
		  if( $self->{verbose} );
	      unlink( $file );
	  }
      }
    }

    chdir( $oldcwd );
  }
}

=head1 INSPECTING CACHE BEHAVIOR

The HTTP::Cache inserts two special headers in the
HTTP::Response object. These can be accessed via the 
HTTP::Response::header()-method.

=over 4

=item X-Cached

This header is inserted and set to 1 if the response is delivered from 
the cache instead of from the server.

=item X-Content-Unchanged

This header is inserted and set to 1 if the content returned is the same
as the content returned the last time this url was fetched. This header
is always inserted and set to 1 when the response is delivered from 
the cache.

=back

=head1 LIMITATIONS

This module has a number of limitations that you should be aware of
before using it.

=over 4

=item -

There is no upper limit to how much diskspace the cache requires. The
only limiting mechanism is that data for urls that haven't been requested
in the last MaxAge hours will be removed from the cache the next time
the program exits.

=item -

Currently, only get-requests that store the result in memory (i.e. do
not use the option to have the result stored directly in a file or
delivered via a callback) is cached. I intend to remove this limitation
in a future version.

=item -

The support for Ranges is a bit primitive. It creates a new object in
the cache for each unique combination of url and range. This will work ok 
as long as you always request the same range(s) for a url.

=item -

The cache doesn't properly check and store all headers in the HTTP
request and response. Therefore, if you request the same url repeatedly
with different sets of headers (cookies, accept-encoding etc), and these
headers affect the response from the server, the cache may return the
wrong response.

=item -

HTTP::Cache has not been tested with threads, and will
most likely not work if you use them.

=back

=head1 CACHE FORMAT

The cache is stored on disk as one file per cached object. The filename
is equal to the md5sum of the url and the Range-header if it exists.
The file contains a set of 
key/value-pairs with metadata (one entry per line) followed by a blank 
line and then the actual data returned by the server.

The last modified date of the cache file is set to the time when the
cache object was last requested by a user.

=head1 AUTHOR

Darren Embry, E<lt>dse -at- sdf -dot- org<gt>
L<http://webonastick.com/>

=head1 GIT REPOSITORY

A git repository containing the source for this module can be found
via https://github.com/dse/HTTP-Cache

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Darren Embry

Based on the HTTP::Cache::Transparent module, Copyright (C) 2004-2007
by Mattias Holmlund

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.


=cut

BEGIN {
  my %me = (dse => 1, dembry => 1);
  if ($me{$ENV{USER}} || $me{$ENV{LOGNAME}}) {
    warn("This version of HTTP::Cache has Honey Badger Superpowers!\n");
  }
}

package LWP::UserAgent::HTTP::Cache;
use warnings;
use strict;
use base "LWP::UserAgent";
sub simple_request {
  my($self, $r, $content_cb, $read_size_hint) = @_;
  
  my $res;

  if( $r->method eq "GET" and
      not defined( $r->header( 'If-Modified-Since' ) ) and
      not defined( $content_cb ) ) {
    print STDERR "Fetching " . $r->uri
      if( $self->{verbose} );
    
    my $url = $r->uri->as_string;
    my $key = $url;
    $key .= "\n" . $r->header('Range')
      if defined $r->header('Range');

    my $filename = $self->{basepath} . $self->_urlhash( $url );

    my $fh;
    my $meta;

    if( -s $filename ) {
      $fh = new IO::File "< $filename"
        or die "Failed to read from $filename";

      $meta = $self->_read_meta( $fh );
      
      if( $meta->{Url} eq $url ) {
        $meta->{'Range'} = "" 
          unless defined( $meta->{'Range'} );

        # Check that the Range is the same for this request as 
        # for the one in the cache.
        if( (not defined( $r->header( 'Range' ) ) ) or
            $r->header( 'Range' ) eq $meta->{'Range'} ) {
          $r->header( 'If-Modified-Since', $meta->{'Last-Modified'} )
            if exists( $meta->{'Last-Modified'} );
          
          $r->header( 'If-None-Match', $meta->{ETag} )
            if( exists( $meta->{ETag} ) );
        }
      }
      else {
        warn "Cache collision: $url and $meta->{Url} have the same md5sum";
      }
    }

    my $time = time;
    my $dont_update = 0;
    if ($self->{noupdate}) {
      if ($self->{noupdateimpatient}) {
	if (defined $meta->{'X-HCT-LastModified'}) {
	  $dont_update = ($self->{noupdate} + $self->{noupdateimpatientfudgefactor}) > ($time - $meta->{'X-HCT-LastModified'});
	} elsif (defined $meta->{'X-HCT-LastUpdated'}) {
	  $dont_update = $self->{noupdate} > ($time - $meta->{'X-HCT-LastUpdated'});
	}
      }
      else {
	if (defined $meta->{'X-HCT-LastUpdated'}) {
	  $dont_update = $self->{noupdate} > ($time - $meta->{'X-HCT-LastUpdated'});
	}
      }
    }
    
    if ($dont_update) {
      print STDERR " from cache without checking with server.\n"
        if $self->{verbose};

      $res = HTTP::Response->new( $meta->{Code} );
      $res->request($r);
      $self->_get_from_cachefile( $filename, $fh, $res, $meta );
      $fh->close() 
        if defined $fh;;

      return $res;
    }

    $res = $self->SUPER::simple_request($r);

    if( $res->code == RC_NOT_MODIFIED ) {
      print STDERR " from cache.\n" 
        if( $self->{verbose} );

      $self->_get_from_cachefile( $filename, $fh, $res, $meta );

      $fh->close() 
        if defined $fh;;

      # We need to rewrite the cache-entry to update X-HCT-LastUpdated
      $self->_write_cache_entry( $filename, $url, $r, $res );
      return $res;
    }
    elsif( defined( $meta->{'X-HCT-LastUpdated'} ) 
	   and not &{$self->{approvecontent}}( $res ) ) {
      print STDERR " from cache since the response was not approved.\n" 
        if( $self->{verbose} );

      $self->_get_from_cachefile( $filename, $fh, $res, $meta );

      $fh->close() 
        if defined $fh;;

      # Do NOT update the cache!

      return $res;
    }      
    else {
      $fh->close() 
        if defined $fh;;

      my $content = $res->content;
      $content = "" if not defined $content;

      if( defined( $meta->{MD5} ) and 
                   md5_hex( $content ) eq $meta->{MD5} ) {
        $res->header( "X-Content-Unchanged", 1 );
        print STDERR " unchanged"
          if( $self->{verbose} );
      }

      print STDERR " from server.\n"
        if( $self->{verbose} );

      $self->_write_cache_entry( $filename, $url, $r, $res )
        if( $res->code == RC_OK or
            $res->code == RC_PARTIAL_CONTENT );
    }
  }
  else {
    # We won't try to cache this request. 
    $res = $self->SUPER::simple_request($r, $content_cb, $read_size_hint );
  }

  return $res;
}

1;
