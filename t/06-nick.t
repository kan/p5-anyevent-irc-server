use strict;
use warnings;
use t::Util;
use Test::Requires 'AnyEvent::IRC::Client';
use Test::More;
use Test::TCP;
use AnyEvent::IRC::Server;
use AE;
use AnyEvent::Debug;

plan tests => 2;

test_tcp(
    server => sub {
        my $port = shift;
        our $SHELL = AnyEvent::Debug::shell "unix/", "/tmp/aedebug.shell";

        my $ircd = AnyEvent::IRC::Server->new(
            port         => $port,
            'servername' => 'fushihara.anyevent.server.irc',
            prepared_cb  => sub {
                my ( $self, $host, $port ) = @_;
            },
        );
        $ircd->reg_cb();
        $ircd->run();
        AE::cv()->recv();
        die 'do not reache here';
    },
    client => sub {
        my $port = shift;

        my $testbot = conn(
            port => $port,
            nick => 'testbot',
        );
        $testbot->skip_first();

        my $collision = conn(
            port => $port,
            nick => 'testbot',
        );
        $collision->is_response('433 * testbot :Nickname already in use');

        undef($testbot); # close original

        my $testbot2 = conn(
            port => $port,
            nick => 'testbot',
        );
        isnt $testbot2->getline(), '433 * testbot :Nickname already in use';
    }
);


