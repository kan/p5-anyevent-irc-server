#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use feature 'say';

use Encode;
use AE;
use AnyEvent::Twitter::Stream;
use AnyEvent::IRC::Server;
use Config::Pit;
use opts;

my $conf = pit_get('twitter.com', require => {
    "username" => "your username on twitter",
    "password" => "your password on twitter",
});

opts my $port => 'Int';
 
my $ircd = AnyEvent::IRC::Server->new(
    port       => $port,
    servername => 'localhost'
);
$ircd->run();

my $streamer = AnyEvent::Twitter::Stream->new(
    username => $conf->{username},
    password => $conf->{password},
    method   => 'filter',
    track    => 'http',
    on_tweet => sub {
        my $tweet = shift;
        $ircd->daemon_cmd_privmsg(
            $tweet->{user}{screen_name} => '#twitter',
            encode( 'utf-8', $tweet->{text} )
        );
        print $tweet->{text} . "\n";
    },
    on_error => sub {
        my $error = shift;
        warn "ERROR: $error";
        AE::cv->send;
    },
    on_eof => sub {
        AE::cv->send;
    },
);

AE::cv->recv;
