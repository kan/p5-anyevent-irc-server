use strict;
use warnings;
use Test::Requires 'AnyEvent::IRC::Client';
use Test::More;
use Test::TCP;
use AnyEvent::IRC::Server;
use AE;

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv();
        my $cv_join = AE::cv();

        my $irc = AnyEvent::IRC::Client->new();
        $irc->reg_cb(
            'irc_001' => sub {
                ok 1, 'irc_001';
            },
            registered => sub {
                ok 1, 'registered';
                $irc->send_srv(JOIN => '#foo');
                $irc->send_srv(PRIVMSG => '#foo', 'yo');
                $irc->send_srv(TOPIC => 'boo');
            },
            sent => sub {
                ok 1, 'sentsrv';
            },
            'publicmsg' => sub {
                my ($irc, $channel, $raw) = @_;
                my $who          = $raw->{prefix} || '*';
                my $channel_name = $raw->{params}->[0];
                my $msg          = $raw->{params}->[1];
                my $command      = $raw->{command};
                is $channel, '#foo';
                is $command, 'PRIVMSG';
                is $who, 'kan!~kan@fushihara.anyevent.server.irc';
                is $msg, 'YEAAAAH!', 'publicmsg';
                $cv->send();
            },
            'join' => sub {
                ok 1, 'join event';
                $cv_join->send();
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
        $cv_join->recv();

        done_testing;
    },
    server => sub {
        my $port = shift;
        my $cv = AE::cv();

        my $ircd = AnyEvent::IRC::Server->new(
            port         => $port,
            'servername' => 'fushihara.anyevent.server.irc'
        );
        $ircd->reg_cb(
            privmsg => sub {
                my ($ircd, $msg, $handle) = @_;
                ok 1, 'privmsg callback!';
                $ircd->send_privmsg('kan', '#foo', 'YEAAAAH!');
            },
        );
        $ircd->run();

        $cv->recv();
    },
);
