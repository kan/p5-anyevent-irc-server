use strict;
use warnings;
use Test::Requires 'AnyEvent::IRC::Client';
use Test::More;
use Test::TCP;
use AnyEvent::IRC::Server;
use AE;

plan tests => 7;

my $port = empty_port();

my $cv = AE::cv();
my $cv_john = AE::cv();

my $ircd = AnyEvent::IRC::Server->new(
    port         => $port,
    'servername' => 'fushihara.anyevent.server.irc',
    prepared_cb  => sub {
        my ( $self, $host, $port ) = @_;
    },
);
$ircd->reg_cb(
    daemon_notice => sub {
        my ($ircd, $nick, $chan, $text) = @_;
        if ($text eq 'yo') {
            ok 1, 'privmsg callback!';
            $ircd->daemon_cmd_notice('kan', '#foo', 'YEAAAAH!');
        }
    },
);
$ircd->run();

my @test = (
    sub {
        my $raw = shift;
        my ($chan, $msg) = @{$raw->{params}};
        is $chan, '#foo';
        is $msg, 'yo';
    },
    sub {
        my $raw = shift;
        my ($chan, $msg) = @{$raw->{params}};
        is $chan, '#foo';
        is $msg, 'YEAAAAH!';
    },
);

my $irc = AnyEvent::IRC::Client->new();
$irc->reg_cb(
    registered => sub {
        ok 1, 'registered';
        $irc->send_srv(JOIN => '#foo');
        $cv_john->send();
    },
    'irc_notice' => sub {
        my ($irc, $raw) = @_;
        my $code = shift @test;
        $code->($raw);
        if (scalar(@test) == 0) {
            $cv->send();
        }
    },
);
$irc->connect(
    '127.0.0.1',
    $port,
    {
        nick     => 'testbot',
        user     => 'testbot',
        real     => 'test bot',
        password => 'kogaidan'
    }
);

my $john = AnyEvent::IRC::Client->new();
$john->reg_cb(
    registered => sub {
        ok 1, 'registered';
        my ($irc) = @_;
        $irc->send_srv(JOIN => '#foo');
        $cv_john->recv();
        $irc->send_srv(NOTICE => '#foo', 'yo');
    },
);
$john->connect(
    '127.0.0.1',
    $port,
    {
        nick     => 'john',
        user     => 'john',
        real     => 'john',
    }
);

$cv->recv();

