#!/usr/bin/perl

# Copyright (C) Intel, Inc.
# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Stream tests for upstream hash balancer module.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/stream stream_upstream_hash/)->plan(4);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

stream {
    %%TEST_GLOBALS_STREAM%%

    upstream hash {
        hash $remote_addr;
        server 127.0.0.1:8082;
        server 127.0.0.1:8083;
    }

    upstream cons {
        hash $remote_addr consistent;
        server 127.0.0.1:8082;
        server 127.0.0.1:8083;
    }

    upstream empty {
        hash $proxy_protocol_addr;
        server 127.0.0.1:8082;
        server 127.0.0.1:8083;
    }

    upstream cempty {
        hash $proxy_protocol_addr consistent;
        server 127.0.0.1:8082;
        server 127.0.0.1:8083;
    }

    server {
        listen      127.0.0.1:8080;
        proxy_pass  hash;
    }

    server {
        listen      127.0.0.1:8081;
        proxy_pass  cons;
    }

    server {
        listen      127.0.0.1:8084;
        proxy_pass  empty;
    }

    server {
        listen      127.0.0.1:8085;
        proxy_pass  cempty;
    }
}

EOF

$t->run_daemon(\&stream_daemon, port(8082));
$t->run_daemon(\&stream_daemon, port(8083));
$t->run();

$t->waitforsocket('127.0.0.1:' . port(8082));
$t->waitforsocket('127.0.0.1:' . port(8083));

###############################################################################

my @ports = my ($port2, $port3) = (port(8082), port(8083));

is(many(10, port(8080)), "$port3: 10", 'hash');
like(many(10, port(8081)), qr/($port2|$port3): 10/, 'hash consistent');

# fallback to round-robin

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.17.1');

like(many(4, port(8084)), qr/$port2: 2, $port3: 2/, 'empty key');
like(many(4, port(8085)), qr/$port2: 2, $port3: 2/, 'empty key - consistent');

}

###############################################################################

sub many {
    my ($count, $port) = @_;
    my (%ports);

    for (1 .. $count) {
        if (stream("127.0.0.1:$port")->io('.') =~ /(\d+)/) {
            $ports{$1} = 0 unless defined $ports{$1};
            $ports{$1}++;
        }
    }

    my @keys = map { my $p = $_; grep { $p == $_ } keys %ports } @ports;
    return join ', ', map { $_ . ": " . $ports{$_} } @keys;
}

###############################################################################

sub stream_daemon {
    my ($port) = @_;

    my $server = IO::Socket::INET->new(
        Proto => 'tcp',
        LocalAddr => '127.0.0.1',
        LocalPort => $port,
        Listen => 5,
        Reuse => 1
    )
        or die "Can't create listening socket: $!\n";

    my $sel = IO::Select->new($server);

    local $SIG{PIPE} = 'IGNORE';

    while (my @ready = $sel->can_read) {
        foreach my $fh (@ready) {
            if ($server == $fh) {
                my $new = $fh->accept;
                $new->autoflush(1);
                $sel->add($new);

            } elsif (stream_handle_client($fh)) {
                $sel->remove($fh);
                $fh->close;
            }
        }
    }
}

sub stream_handle_client {
    my ($client) = @_;

    log2c("(new connection $client)");

    $client->sysread(my $buffer, 65536) or return 1;

    log2i("$client $buffer");

    $buffer = $client->sockport();

    log2o("$client $buffer");

    $client->syswrite($buffer);

    return 1;
}

sub log2i { Test::Nginx::log_core('|| <<', @_); }
sub log2o { Test::Nginx::log_core('|| >>', @_); }
sub log2c { Test::Nginx::log_core('||', @_); }

###############################################################################
