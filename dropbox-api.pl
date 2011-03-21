#!perl

use strict;
use Cwd 'abs_path';
use Data::Dumper;
use DateTime;
use DateTime::Format::Strptime;
use File::Basename qw(dirname);
use File::Spec::Functions qw(abs2rel);
use Getopt::Std;
use JSON;
use Net::Dropbox::API;
use Path::Class;

my %opts;
getopts('ndvD', \%opts);

my $dry     = $opts{n};
my $delete  = $opts{d};
my $verbose = $opts{v};
my $debug   = $opts{D};

my ($mode, $remote_base, $local_base) = @ARGV;

$remote_base = '/' . $remote_base if $remote_base!~m|^/|;

# connect dropbox
my $config_file = file( dirname(__FILE__), $ENV{'CONFIG_PATH'} || 'dropbox-config.json' );
my $config = decode_json($config_file->slurp);
$config->{key} or die 'please set config key.';
$config->{secret} or die 'please set config secret.';
$config->{access_token} or die 'please set config access_token.';
$config->{access_secret} or die 'please set config access_secret.';
my $box = Net::Dropbox::API->new($config);
$box->context('dropbox');

binmode STDOUT, ':utf8';

if ($mode eq 'ls') {
    &ls();
} elsif ($mode eq 'find') {
    &find();
} elsif ($mode eq 'sync') {
    &sync();
} else {
    die "unknown option $mode";
}

exit(0);


sub ls {
    $remote_base=~s|^/||;
    my $list = $box->list($remote_base);
    for my $content (@{$list->{contents}}) {
        if ($verbose) {
            print Dumper($content);
            next;
        }
        printf "%4s %10s %s %s\n",
            ($content->{is_dir} ? 'dir' : 'file'),
            ($content->{is_dir} ? '-' : $content->{size}),
            $content->{modified},
            $content->{path};
    }
}


sub find {
    &_find($remote_base, sub { printf "%s\n", shift->{path} });
}

sub _find {
    my ($remote_path, $callback) = @_;
    $remote_path=~s|^/||;
    my $list = $box->list($remote_path);
    for my $content (@{$list->{contents}}) {
        $callback->($content);
        if ($content->{is_dir}) {
            &_find($content->{path}, $callback);
        }
    }
}


sub sync {
    $local_base = dir(abs_path($local_base));
    print "remote_base: $remote_base\n" if $verbose;
    print "local_base: $local_base\n" if $verbose;
    
    die "not found $local_base" unless -d $local_base;
    
    my $remote_map = {};
    
    # Sun, 26 Dec 2010 21:43:11 +0000
    my $strp = new DateTime::Format::Strptime(
        pattern => '%a, %d %b %Y %T %z'
    );
    
    print "** download **\n" if $verbose;
    
    &_find($remote_base, sub {
        my $content = shift;
        my $remote_path = $content->{path};
        my $rel_path = abs2rel($remote_path, $remote_base);
        $remote_map->{$rel_path}++;
        printf "check: %s\n", $rel_path if $debug;
        if ($content->{is_dir}) {
            my $local_path = dir($local_base, $rel_path);
            printf "remote: %s\n", $remote_path if $debug;
            printf "local:  %s\n", $local_path if $debug;
            if (!-d $local_path) {
                $local_path->mkpath unless $dry;
                printf "mkpath %s\n", $local_path;
            } else {
                printf "skip %s\n", $rel_path if $verbose;
            }
        } else {
            my $local_path = file($local_base, $rel_path);
            my $remote_epoch = $strp->parse_datetime($content->{modified})->epoch;
            my $local_epoch = -f $local_path ? $local_path->stat->mtime : '-';
            my $remote_size = $content->{bytes};
            my $local_size = -f $local_path ? $local_path->stat->size : '-';
            printf "remote: %10s %10s %s\n",
                $remote_epoch, $remote_size, $remote_path if $debug;
            printf "local:  %10s %10s %s\n",
                $local_epoch, $local_size, $local_path if $debug;
            
            if ((!-f $local_path) or
                ($remote_size != $local_size) or
                ($remote_epoch > $local_epoch)) {
                printf "download %s\n", $local_path;
                printf "mkpath %s\n", $local_path->dir unless -d $local_path->dir;
                return if $dry;
                $local_path->dir->mkpath unless -d $local_path->dir;
                my $local_path_tmp = $local_path . '.dropbox-api.tmp';
                $box->getfile(substr($content->{path}, 1), $local_path_tmp);
                unless (rename($local_path_tmp, $local_path)) {
                    unlink($local_path_tmp);
                    warn "rename failure " . $local_path_tmp;
                }
            } else {
                printf "skip %s\n", $rel_path if $verbose;
            }
        }
    });
    
    return unless $delete;
    
    print "** delete **\n" if $verbose;
    
    my @deletes;
    $local_base->recurse(
        preorder => 0,
        depthfirst => 1,
        callback => sub {
            my $local_path = shift;
            next if $local_path eq $local_base;
            my $rel_path = abs2rel($local_path, $local_base);
            if (exists $remote_map->{$rel_path}) {
                printf "skip $rel_path\n" if $verbose;
            } elsif (-f $local_path) {
                printf "remove $rel_path\n";
                push @deletes, $local_path;
            } elsif (-d $local_path) {
                printf "rmtree $rel_path\n";
                push @deletes, $local_path;
            }
        }
    );
    
    return if $dry;
    
    for my $local_path (@deletes) {
        if (-f $local_path) {
            $local_path->remove;
        } elsif (-d $local_path) {
            $local_path->rmtree;
        }
    }
}

exit(0);