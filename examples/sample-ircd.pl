use strict;
use warnings;
use AE;
use AnyEvent::IRC::Server;
use Getopt::Long;

my $port = 6667;

GetOptions(
    'p|port=i' => \$port,
);

my $ircd = AnyEvent::IRC::Server->new(
    port         => $port,
    'servername' => 'chat.64p.org'
);
$ircd->run();

print "irc server is ready in irc://0:$port/\n";

AE::cv->recv();
