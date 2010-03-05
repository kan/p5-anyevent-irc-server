#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use Encode;
use AE;
use AnyEvent::IRC::Server;
use AnyEvent::IRC::Client;
use Lingua::JA::Gal;
use opts;
use Data::Dumper;

opts my $port => 'Int';
 
my $ircd = AnyEvent::IRC::Server->new(
    port       => $port,
    servername => 'localhost'
);
$ircd->run();

my $ic = AnyEvent::IRC::Client->new;
$ic->reg_cb(
    registered => sub {
        my $self = shift;
        $ic->enable_ping(60);
    },
    publicmsg => sub {
        my ( $self, $channel, $msg ) = @_;
        my ( undef, $message ) = @{$msg->{params}};
        my $nick = $msg->{prefix};
        $nick =~ s/\!.*$//;

        $ircd->daemon_cmd_privmsg(
            $nick => $channel,
            encode('utf8', Lingua::JA::Gal->gal(decode('utf8',$message))),
        );
    }
);
$ic->send_srv( 'JOIN', '#yokohama.pm' );
$ic->connect(
    'irc.freenode.net', 6667 => {
        nick => 'galbot',
        user => 'galbot',
        real => 'galbot',
    }
);

AE::cv->recv;
