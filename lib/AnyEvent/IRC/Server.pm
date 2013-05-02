package AnyEvent::IRC::Server;

use strict;
use warnings;
our $VERSION = '0.03';
use base qw/Object::Event/;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::IRC::Util qw/parse_irc_msg/;
use Sys::Hostname;
use POSIX;
use Scalar::Util qw/refaddr/;

use Class::Accessor::Lite (
    rw => [
        qw(host port handles servername channels topics spoofed_nick prepared_cb nick2handle)
    ],
);

my $CRLF = "\015\012";

BEGIN {
    no strict 'refs';
    while (my ($code, $name) = each %AnyEvent::IRC::Util::RFC_NUMCODE_MAP) {
        *{"${name}"} = sub () { $code };
    }
};

sub debugf {
    return unless $ENV{AEIS_DEBUG};
    require Data::Dumper;
    require Term::ANSIColor;
    local $Data::Dumper::Terse=1;
    local $Data::Dumper::Indent=0;
    my $fmt = shift;
    my $s = sprintf $fmt, (map {
        ref($_) ? (
            Data::Dumper::Dumper($_)
        ) : (defined($_) ? $_ : '<<UNDEF>>')
    } @_);
    my ($package, $filename, $line) = caller(0);
    $s .= " at $filename line $line\n";
    print Term::ANSIColor::colored(["cyan"], $s);
}

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
        handles      => {}, # refaddr($handle) => $handle
        channels     => {},
        topics       => {},
        spoofed_nick => {},
        nick2handle  => {}, # $nick => $hanldle,
        welcome      => 'Welcome to the my IRC server',
        servername   => hostname(),
        network      => 'AnyEventIRCServer',
        ctime        => POSIX::strftime( '%Y-%m-%d %H:%M:%S', localtime() ),
        channel_chars => '#&',
        prepared_cb  => sub {
            my ($self, $host, $port) = @_;
            print "$class is ready on : $host:$port\n";
        },
        @_,
    );

    
    my $say = sub {
        my ($handle, $cmd, @args) = @_;
        my $msg = mk_msg_ex($self->host, $cmd, $handle->{nick}, @args);
        debugf("Sending '%s'", $msg);
        $msg .= $CRLF;
        $handle->push_write($msg)
    };
    my $need_more_params = sub {
        my ($handle, $cmd) = @_;
        $say->($handle, ERR_NEEDMOREPARAMS, $cmd, 'Not enough parameters');
    };
    $self->reg_cb(
        nick => sub {
            my ($self, $msg, $handle) = @_;
            my ($nick) = @{$msg->{params}};
            unless (defined $nick) {
                return $need_more_params->($handle, 'NICK');
            }
            if ($self->nick2handle->{$nick}) {
                return $say->($handle, ERR_NICKNAMEINUSE, $nick, 'Nickname already in use');
            }
            debugf("Set nick: %s", $nick);
            $handle->{nick} = $nick;
            $self->nick2handle->{$nick} = $handle;
            # TODO: broadcast to each user
        },
        user => sub {
            my ($self, $msg, $handle) = @_;
            my ($user, $host, $server, $realname) = @{$msg->{params}};
            # TODO: Note that hostname and servername are normally ignored by the IRC server when the USER command comes from a directly connected client (for security reasons)
            $handle->{user} = $user;
            $handle->{hostname} = $host;
            $handle->{servername} = $server;
            $handle->{realname} = $realname;

            $say->( $handle, RPL_WELCOME(), $self->{welcome} );
            $say->( $handle, RPL_YOURHOST(), "Your host is @{[ $self->servername ]} [@{[ $self->servername ]}/@{[ $self->port ]}]. @{[ ref $self ]}/$VERSION" ); # 002
            $say->( $handle, RPL_CREATED(), "This server was created $self->{ctime}");
            $say->( $handle, RPL_MYINFO(), "@{[ $self->servername ]} @{[ ref $self ]}-$VERSION" ); # 004
            $say->( $handle, ERR_NOMOTD(), "MOTD File is missing" );
        },
        'join' => sub {
            my ($self, $msg, $handle) = @_;
            my ($chans) = @{$msg->{params}};
            unless ($chans) {
                return $need_more_params->($handle, 'JOIN');
            }
            for my $chan ( split /,/, $chans ) {
                my $nick = $handle->{nick};
                debugf("%s joined to %s", $nick, $chans);
                $self->channels->{$chan}->{handles}->{$nick} = $handle;

                # server reply
                $say->( $handle, RPL_TOPIC(), $chan, $self->topics->{$chan} || '' );
                for my $handle (values %{$self->channels->{$chan}->{handles}}) {
                    next unless $handle->{nick};
                    next if $self->spoofed_nick->{$handle->{nick}};
                    $say->( $handle, RPL_NAMREPLY(), $chan, $handle->{nick} );
                }
                $say->( $handle, RPL_ENDOFNAMES(), $chan, 'End of NAMES list.' );

                # send join message
                my $comment = sprintf '%s!%s@%s', $nick, $nick, $self->servername;
                # my $comment = sprintf '%s!%s@%s', $nick, $handle->{user}, $handle->{servername};
                my $raw = mk_msg_ex($comment, 'JOIN', $chan) . $CRLF;
                for my $handle (values %{$self->channels->{$chan}->{handles}}) {
                    next unless $handle->{nick};
                    next if $self->spoofed_nick->{$handle->{nick}};
                    $handle->push_write($raw);
                }
                $self->event('daemon_join' => $nick, $chan);
            }
        },
        part => sub {
            my ($self, $msg, $handle) = @_;
            my ($chans, $text) = @{$msg->{params}};
            unless ($chans) {
                return $need_more_params->($handle, 'PART');
            }
            for my $chan ( split /,/, $chans ) {
                my $nick = $handle->{nick};
                $self->_intern_part($nick, $chan, $text);
                $self->event('daemon_part' => $nick, $chan);
            }
        },
        topic => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $topic) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'TOPIC');
            }
            if ($topic) {
                $say->( $handle, RPL_TOPIC, $self->topics->{$chan} );
                my $nick = $handle->{nick};
                $self->_intern_topic($nick, $chan, $topic);
                $self->event('daemon_topic' => $nick, $chan, $topic);
            } else {
                $say->( $handle, RPL_NOTOPIC, $chan, 'No topic is set' );
            }
        },
        'privmsg' => sub {
            my ($irc, $msg, $handle) = @_;
            my ($chan, $text) = @{$msg->{params}};
            unless ($chan) {
                return $need_more_params->($handle, 'PRIVMSG');
            }
            my $nick = $handle->{nick};
            if ($nick eq '*') {
                warn 'Nick was not set.';
            }
            $self->_intern_privmsg($nick, $chan, $text);
            $self->event('daemon_privmsg' => $nick, $chan, $text);
        },
        'notice' => sub {
            my ($irc, $raw, $handle) = @_;
            my ($chan, $msg) = @{$raw->{params}};
            unless ($msg) {
                return $need_more_params->($handle, 'NOTICE');
            }
            my $nick = $handle->{nick};
            $self->_intern_notice($nick, $chan, $msg);
            $self->event('daemon_notice' => $nick, $chan, $msg);
        },
        'list' => sub {
            my ($irc, $raw, $handle) = @_;
            my ($chans, $msg) = @{$raw->{params}};
            $self->_intern_list($handle, $chans);
        },
        who => sub {
            my ($irc, $msg, $handle) = @_;
            my ($name) = @{$msg->{params}};

             unless ( $self->channels->{$name} ) {
                 # TODO: ZNC calls '*'.
                 # AEIS should process it.
                debugf("The channel is not listed: $name");
                $say->( $handle, RPL_ENDOFWHO(), 'END of /WHO list');
                return;
                # return $need_more_params->($handle, 'WHO'); # TODO
             }

            $say->( $handle, RPL_WHOREPLY(), $name, $handle->{user}, $handle->{hostname}, $handle->{servername}, $handle->{nick},"H:1", $handle->{realname});
            $say->( $handle, RPL_ENDOFWHO(), 'END of /WHO list');
        },
        ping => sub {
            my ($irc, $msg, $handle) = @_;
            $say->( $handle, 'PONG', $msg->{params}->[0]);
        },
    );
    return $self;
}

sub _server_comment {
    my ($self, $nick) = @_;
    return sprintf '%s!~%s@%s', $nick, $nick, $self->servername;
}

sub _send_chan_msg {
    my ($self, $nick, $chan, @args) = @_;
    # send join message
    my $handle = $self->channels->{$chan}->{handles}->{$nick};
    my $comment = sprintf '%s!%s@%s', $nick, $handle->{user} || $nick, $handle->{servername} || $self->servername;
    my $raw = mk_msg_ex($comment, @args);
    debugf("_send_chan_msg: %s", $raw);
    $raw .= $CRLF;
    if ($self->is_channel_name($chan)) {
        for my $handle (values %{$self->channels->{$chan}->{handles}}) {
            next unless $handle->{nick};
            next if $handle->{nick} eq $nick;
            next if $self->spoofed_nick->{$handle->{nick}};
            $handle->push_write($raw);
        }
    } else {
        # private talk
        # TODO: TOO SLOW
        my $handle = $self->nick2handle->{$chan};
        if ($handle) {
            $handle->push_write($raw);
        }
    }
}

sub run {
    my $self = shift;
    tcp_server $self->{host}, $self->{port}, sub {
        my ($fh, $host, $port) = @_;
        my $handle = AnyEvent::Handle->new(
            on_error => sub {
                my ($handle) = @_;
                $self->event('on_error' => $handle);
            },
            on_eof => sub {
                my ($handle) = @_;
                $self->event('on_eof' => $handle);
                # TODO: part from each channel
                if (my $nick = $handle->{nick}) {
                    delete $self->nick2handle->{$nick};
                }
                delete $self->handles->{refaddr($handle)};
            },
            fh => $fh,
        );
        $handle->{nick} = '*';
        $handle->on_read(sub {
            $handle->push_read(line => sub {
                my ($handle, $line, $eol) = @_;
                my $msg = parse_irc_msg($line);
                $self->handle_msg($msg, $handle);
            });
        });
        $self->handles->{refaddr($handle)} = $handle;
    }, $self->prepared_cb();
}

sub handle_msg {
    my ($self, $msg, $handle) = @_;
    my $event = lc($msg->{command});
       $event =~ s/^(\d+)$/irc_$1/g;
    debugf("%s %s", $event, $msg);
    $self->event($event, $msg, $handle);
}

# -------------------------------------------------------------------------

sub add_spoofed_nick {
    my ($self, $nick) = @_;
    $self->{spoofed_nick}->{$nick} = 1;
}


# -------------------------------------------------------------------------

sub daemon_cmd_join {
    my ($self, $nick, $chan, $msg) = @_;
    return if $self->channels->{$chan}->{handles}->{$nick};
    $self->add_spoofed_nick($nick);
    $self->_intern_join($nick, $chan, $self->nick2handle->{$nick});
}

sub daemon_cmd_kick {
    my ($self, $kicker, $chan, $kickee, $comment) = @_;
    $self->_intern_kick($kicker, $chan, $kickee, $comment);
}

sub daemon_cmd_topic {
    my ($self, $nick, $chan, $topic) = @_;
    $self->_intern_topic($nick, $chan, $topic);
}

sub daemon_cmd_part {
    my ($self, $nick, $chan, $msg) = @_;
    $self->_intern_part($nick, $chan, $msg);
}

sub daemon_cmd_privmsg {
    my ($self, $nick, $chan, $msg) = @_;
    $self->_intern_privmsg($nick, $chan, $msg);
}

sub daemon_cmd_notice {
    my ($self, $nick, $chan, $msg) = @_;
    debugf('%s', [$nick, $chan, $msg]);
    $self->_intern_notice($nick, $chan, $msg);
}

# -------------------------------------------------------------------------

sub _intern_list {
    my ($self, $handle, $chans) = @_;

    my $nick = $handle->{nick};
    my $comment = $self->_server_comment($nick);
    my $send = sub {
        my $raw = mk_msg_ex($comment, @_) . $CRLF;
        $handle->push_write($raw);
    };
    my $send_rpl_list = sub {
        my $chan = shift;
        $send->(RPL_LIST, $nick, $chan, scalar keys %{$self->channels->{$chan}->{handles}},  ':'.($self->topics->{$chan} || ''));
    };
    $send->(RPL_LISTSTART, $nick, 'Channel', ':Users', 'Name');
    if ($chans) {
        for my $chan (split /,/, $chans) {
            if ($self->channels->{$chan}) {
                $send_rpl_list->($chan);
            }
        }
    } else {
        my $channels = $self->channels;
        while (my ($chan, $val) = each %$channels) {
            $send_rpl_list->($chan);
        }
    }
    $send->(RPL_LISTEND, $nick, 'End of /LIST');
}

sub _intern_privmsg {
    my ($self, $nick, $chan, $text) = @_;
    $self->_send_chan_msg($nick, $chan, 'PRIVMSG', $chan, $text);
}

sub _intern_notice {
    my ($self, $nick, $chan, $text) = @_;
    debugf('%s', [$nick, $chan, $text]);
    $self->_send_chan_msg($nick, $chan, 'NOTICE', $chan, $text);
}

sub _intern_topic {
    my ($self, $nick, $chan, $topic) = @_;
    $self->topics->{$chan} = $topic;
    $self->_send_chan_msg($nick, $chan, 'TOPIC', $chan, $self->topics->{$chan});
}

sub _intern_join {
    my ($self, $nick, $chan, $handle) = @_;
    $self->channels->{$chan}->{handles}->{$nick} = $handle;
    $self->_send_chan_msg($nick, $chan, 'JOIN', $chan);
}

sub _intern_part {
    my ($self, $nick, $chan, $msg) = @_;
    $msg ||= $nick;

    # send part message
    $self->_send_chan_msg($nick, $chan, 'PART', $chan, $msg);
    delete $self->channels->{$chan}->{handles}->{$nick};
}

# /KICK <channel> <user> [<comment>]
# use this line in /kick: $self->event('daemon_kick' => $kicker, $chan, $kickee, $comment);
sub _intern_kick {
    my ($self, $kicker, $chan, $kickee, $comment) = @_;

    # TODO: implement
    # TODO: oper check
    my $handle = $self->channels->{$chan}->{handles}->{$kicker};
    my $cmt_irc = sprintf '%s!%s@%s', $kicker, $handle->{user} || $kicker , $handle->{servername} || $self->servername;
    my $raw = mk_msg_ex($cmt_irc, 'KICK', $chan, $kickee, $comment) . $CRLF;
    for my $handle (values %{$self->channels->{$chan}->{handles}}) {
        $handle->push_write($raw);
    }
    delete $self->channels->{$chan}->{handles}->{$kickee};
}

# -------------------------------------------------------------------------

sub is_channel_name {
    my ( $self, $string ) = @_;
    my $cchrs = $self->{channel_chars};
    $string =~ /^([\Q$cchrs\E]+)(.+)$/;
}

sub mk_msg_ex {
    my ( $prefix, $command, @params ) = @_;
    my $msg = "";

    $msg .= defined $prefix ? ":$prefix " : "";
    $msg .= "$command";

    my $trail;
    debugf("%s", \@params);
    if ( @params >= 2 ) {
        $trail = pop @params;
    }

    # FIXME: params must be counted, and if > 13 they have to be
    # concationated with $trail
    map { $msg .= " $_" } @params;

    $msg .= defined $trail ? " :$trail" : "";

    return $msg;
}

1;
__END__

=head1 NAME

AnyEvent::IRC::Server - An event based IRC protocol server API

=head1 SYNOPSIS

  use AnyEvent::IRC::Server;

=head1 DESCRIPTION

AnyEvent::IRC::Server is

=head1 ROADMAP

    - useful for XIRCD
    -- authentication

    - useful for public irc server
    -- anti flooder
    -- limit nick length
    -- detect nick colision
    -- support /kick
    -- mode support
    -- who support

=head1 DEBUGGING

You can trace events by L<Object::Event>'s feature.

Use the environment variable B<PERL_OBJECT_EVENT_DEBUG>

    export PERL_OBJECT_EVENT_DEBUG=2

=head1 AUTHOR

Kan Fushihara E<lt>default {at} example.comE<gt>

Tokuhiro Matsuno

=head1 SEE ALSO

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
