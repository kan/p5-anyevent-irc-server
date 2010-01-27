use strict;
use warnings;
use Test::Requires 'AnyEvent::IRC::Client';
use Test::More;
use Test::TCP;
use AnyEvent::IRC::Server;
use AE;

plan tests => 4;

my $port = empty_port();

my $cv = AE::cv();
my $cv_john = AE::cv();

my $ircd = AnyEvent::IRC::Server->new(
    port         => $port,
    'servername' => 'fushihara.anyevent.server.irc',
    prepared_cb  => sub { },
);
$ircd->run();

my @responses;
my $irc = AnyEvent::IRC::Client->new();
$irc->reg_cb(
    registered => sub {
        ok 1, 'registered';
        $irc->send_srv(JOIN => '#foo');
        $irc->send_srv('TOPIC' => '#foo', 'hoge');
        $irc->send_srv(JOIN => '#bar');
        $irc->send_srv('TOPIC' => '#bar', 'fuga');
        $irc->send_srv(JOIN => '#baz');
        $irc->send_srv('LIST');
    },
    'irc_321' => sub {
        my ($irc, $raw) = @_;
        is_deeply $raw,
          {
            'params'  => ['testbot', 'Channel', 'Users Name'],
            'command' => '321',
            'prefix'  => 'testbot!~testbot@fushihara.anyevent.server.irc'
          }, 'RPL_LISTSTART';
    },
    'irc_322' => sub {
        my ($irc, $raw) = @_;
        push @responses, join(" ", @{$raw->{params}});
    },
    'irc_323' => sub {
        my ($irc, $raw) = @_;
        is_deeply $raw,
          {
            'params'  => [ 'testbot', 'End of /LIST' ],
            'command' => '323',
            'prefix'  => 'testbot!~testbot@fushihara.anyevent.server.irc'
          }, 'RPL_LISTEND';
        $cv->send();
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

$cv->recv();

is_deeply [ sort @responses ],
  [ 'testbot #bar 1 :fuga', 'testbot #baz 1 :', 'testbot #foo 1 :hoge' ], 'RPL_LIST';

