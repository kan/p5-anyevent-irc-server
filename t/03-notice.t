use strict;
use warnings;
use t::Util;
use Test::Requires 'AnyEvent::IRC::Client';
use Test::More;
use Test::TCP;
use AnyEvent::IRC::Server;
use AE;
use AnyEvent::Debug;

plan tests => 10;

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
        $ircd->reg_cb(
            'on_eof' => sub {
                my $ircd = shift;
            },
            'on_error' => sub {
                my $ircd = shift;
            },
            daemon_notice => sub {
                my ( $ircd, $nick, $chan, $text ) = @_;
                if ( $text eq 'yo' ) {
                    ok 1, 'privmsg callback!';
                    $ircd->daemon_cmd_notice( 'kan', '#foo', 'YEAAAAH!' );
                }
                isnt $text, 'YEAAAAH!';
            },
        );
        $ircd->run();
        AE::cv()->recv();
        die 'do not reache here';
    },
    client => sub {
        my $port = shift;
        my $testbot = conn(
            port => $port,
            nick     => 'testbot',
        );
        $testbot->send_srv('join' => '#foo');
        $testbot->skip_first();
        $testbot->is_response('332 testbot #foo :');
        $testbot->is_response('353 testbot #foo :testbot');
        $testbot->is_response('366 testbot #foo :End of NAMES list.');
        $testbot->is_response(':testbot!testbot@fushihara.anyevent.server.irc JOIN #foo');

        # John is comming
        my $john = conn(
            port => $port,
            nick => 'john'
        );
        $john->send_srv('join' => '#foo');
        $john->send_srv('notice' => '#foo', 'yo');
        $john->skip_first('332 testbot #foo ');

        # test.
        $testbot->is_response('353 testbot #foo :testbot');
        $testbot->is_response(':john!john@fushihara.anyevent.server.irc JOIN #foo');
        $testbot->is_response(':john!john@* NOTICE #foo :yo');
        $testbot->is_response(':kan!kan@fushihara.anyevent.server.irc NOTICE #foo :YEAAAAH!');
    }
);


