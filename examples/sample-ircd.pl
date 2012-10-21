use strict;
use warnings;
use feature 'say';
use AE;
use AnyEvent::IRC::Server;
use Getopt::Long;

$|++; # do not buffering stdout

my $port = 6667;

GetOptions(
    'p|port=i' => \$port,
);

my $ircd = AnyEvent::IRC::Server->new(
    host         => '127.0.0.1',
    port         => $port,
    'servername' => 'localhost'
);
$ircd->reg_cb(
    daemon_join => sub {
        my ($irc, $nick, $chan) = @_;
        say "join: $nick, $chan";
    },
    daemon_part => sub {
        my ($irc, $nick, $chan) = @_;
        say "part: $nick, $chan";
    },
    daemon_topic => sub {
        my ($irc, $nick, $chan, $topic) = @_;
        say "topic: $nick, $chan, $topic";
    },
    daemon_privmsg => sub {
        my ($irc, $nick, $chan, $text) = @_;
        say "privmsg: $nick, $chan, $text";
    },
    daemon_notice => sub {
        my ($irc, $nick, $chan, $text) = @_;
        say "notice: $nick, $chan, $text";
    },
);
$ircd->run();

print "irc server is ready in irc://0:$port/\n";

AE::cv->recv();
