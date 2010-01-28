use strict;
use warnings;
use AnyEvent;
use Test::Requires 'Test::TCP';
use Test::Requires 'AnyEvent::IRC::Server';
use AE;
use AnyEvent::IRC::Client;
use Test::More;
use AnyEvent::IRC::Util qw/encode_ctcp/;
use Encode qw/decode_utf8/;
use Data::Dumper;

sub U ($) { decode_utf8(@_) }

my @TESTCASES = (
    {
        'params'  => [ 'john', 'Welcome to the my IRC server' ],
        'command' => '001',
        'prefix'  => undef
    },
    {
        'params' => [
            'john',
'Your host is simple.poco.server.irc [simple.poco.server.irc/10001]. AnyEvent::IRC::Server/0.01'
        ],
        'command' => '002',
        'prefix'  => undef
    },
    {
        'params'  => [ 'john', 'This server was created 2010-01-26 01:50:24' ],
        'command' => '003',
        'prefix'  => undef
    },
    {
        'params' =>
          [ 'john', 'simple.poco.server.irc AnyEvent::IRC::Server-0.01' ],
        'command' => '004',
        'prefix'  => undef
    },
    {
        'params'  => [ 'john', 'MOTD File is missing' ],
        'command' => '422',
        'prefix'  => undef
    },
    {
        'params'  => [ 'john', '#foo' ],
        'command' => '332',
        'prefix'  => undef
    },
    {
        'params'  => [ 'john', '#foo', 'duke' ],
        'command' => '353',
        'prefix'  => undef
    },
    {
        'params'  => [ '#foo' ],
        'command' => 'JOIN',
        'prefix'  => 'john!john@simple.poco.server.irc'
    },
    {
        'params'  => [ 'john', '#finished' ],
        'command' => '332',
        'prefix'  => undef
    },
    {
        'params'  => [ 'john', '#finished', 'duke' ],
        'command' => '353',
        'prefix'  => undef
    },
    {
        'params'  => [ '#finished' ],
        'command' => 'JOIN',
        'prefix'  => 'john!john@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo' ],
        'command' => 'JOIN',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params' => [
                        'john',
                        '#foo',
                        'john',
                        '*',
                        '0',
                        'john',
                        'H:1',
                        'john'
                    ],
        'command' => '352', # RPL_WHOREPLY
        'prefix' => undef
    },
    {
      'params' => [
                    'john',
                    'END of /WHO list'
                  ],
      'command' => '315', # RPL_ENDOFWHO
      'prefix' => undef
    },
    {
       'params' => [
                     'john',
                     '#finished',
                     'john',
                     '*',
                     '0',
                     'john',
                     'H:1',
                     'john'
                   ],
       'command' => '352', # RPL_WHOREPLY
       'prefix' => undef
    }, 
    {
      'params' => [
                    'john',
                    'END of /WHO list'
                  ],
      'command' => '315', # RPL_ENDOFWHO
      'prefix' => undef
    },
    {
        'params'  => [ 'john', 'PRIVATE TALK' ],
        'command' => 'PRIVMSG',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'THIS IS PRIVMSG' ],
        'command' => 'PRIVMSG',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'THIS IS NOTICE' ],
        'command' => 'NOTICE',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'THIS IS にほんご' ],
        'command' => 'PRIVMSG',
        'prefix' => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', "\x01ACTION too\x01" ],
        'command' => 'PRIVMSG',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'DNBK' ],
        'command' => 'PRIVMSG',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'kan' ],
        'command' => 'KICK',
        'prefix'  => 'SERVER!SERVER@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', '*** is GOD' ],
        'command' => 'TOPIC',
        'prefix'  => 'SERVER!SERVER@simple.poco.server.irc'
    },
    {
        'params'  => [ '#foo', 'parter' ],
        'command' => 'PART',
        'prefix'  => 'parter!parter@simple.poco.server.irc'
    },
    {
        'params'  => [ '#finished' ],
        'command' => 'JOIN',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    },
    {
        'params'  => [ '#finished', 'FINISHED!' ],
        'command' => 'PRIVMSG',
        'prefix'  => 'tester!tester@simple.poco.server.irc'
    }
);

test_tcp(
    client => sub {
        my $port = shift;
        my $cv = AE::cv();

        my $i = 0;
        my @holder;

        # tester thread
        my $tester = AnyEvent::IRC::Client->new();
        $tester->reg_cb(
            irc_001 => sub {
                my ($irc) = @_;
                $irc->send_msg("JOIN", '#foo');
            },
            join => sub {
                my ($irc, $nick, $chan, $is_me) = @_;
                if ($chan eq '#foo') {
                    # just want delay

                    my $t; $t = AE::timer(1, 0, sub {
                        $irc->send_msg("PRIVMSG", 'john', "PRIVATE TALK");
                        $irc->send_msg("PRIVMSG", '#foo', "THIS IS PRIVMSG");
                        $irc->send_msg("NOTICE", '#foo', "THIS IS NOTICE");
                        $irc->send_msg("PRIVMSG", '#foo', "THIS IS にほんご");
                        $irc->send_msg("PRIVMSG", '#foo', encode_ctcp(['ACTION', "too"]));
                        $irc->send_msg("PRIVMSG", '#foo', "DNBK");
                        $irc->send_msg("JOIN", '#finished');
                        undef $t;
                    });
                    push @holder, $t;
                } elsif ($chan eq '#finished') {
                    my $t; $t = AE::timer(1, 0, sub {
                        $irc->send_msg("PRIVMSG", '#finished', "FINISHED!");
                        undef $t;
                    });
                    push @holder, $t;
                }
            },
        );

        # create mobirc.
        my @log;
        my $john = AnyEvent::IRC::Client->new();
        $john->reg_cb(
            irc_001 => sub {
                my ($irc) = @_;
                $irc->send_msg("JOIN", '#foo');
                $irc->send_msg("JOIN", '#finished');
                $tester->connect(
                    '127.0.0.1',
                    $port,
                    {
                        nick    => 'tester',
                        timeout => 1,
                    }
                );
            },
            'irc_*' => sub {
                my ($irc, $raw) = @_;
                my $expected = shift @TESTCASES or die "hmm... test cases are not enough";
                my $msg = $raw->{command} . ' : ' . join(", ", @{$raw->{params}}) . ' == ' .  join(", ", @{$expected->{params}});
                is_deeply $raw, $expected, $msg;
                if ($raw->{command} ne $expected->{command}) {
                    diag Dumper($raw);
                }
            },
            publicmsg => sub {
                my ($irc, $channel, $raw) = @_;
                my ($chan, $msg) = @{ $raw->{params} };
                if ($chan eq '#finished') {
                    $cv->send(1);
                }
            },
        );
        $john->connect(
            '127.0.0.1',
            $port,
            {
                nick    => 'john',
                user    => 'john',
            }
        );

        $cv->recv();

        done_testing;
    },
    server => sub {
        my $port = shift;

        my $ircd = AnyEvent::IRC::Server->new(
            servername => 'simple.poco.server.irc',
            network    => 'SimpleNET',
            port       => $port,
            ctime      => '2010-01-26 01:50:24',
        );
        for my $nick (qw/SERVER kan parter/) {
            $ircd->add_spoofed_nick($nick);
            $ircd->daemon_cmd_join( $nick => '#foo' );
        }
        $ircd->reg_cb(
            'daemon_privmsg' => sub {
                my ($ircd, $nick, $chan, $msg) = @_;
                $nick =~ s/!.+//;
                if ($msg eq 'DNBK') {
                    $ircd->daemon_cmd_kick( 'SERVER', '#foo', 'kan' );
                    $ircd->daemon_cmd_topic( 'SERVER', '#foo', '*** is GOD' );
                    $ircd->daemon_cmd_part( 'parter', '#foo' );
                }
                if ($nick eq 'john') {
                    $ircd->daemon_cmd_privmsg('SERVER', '#foo', "ECHO: $msg");
                }
            },
        );
        $ircd->run();

        AE::cv->recv();
    },
);
