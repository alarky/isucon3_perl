package Isucon3::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use JSON qw/ decode_json /;
use Digest::SHA qw/ sha256_hex /;
use File::Temp qw/ tempfile /;
use IO::Handle;
use Encode;
use Time::Piece;
use Cache::Memcached::Fast;
use Text::Markdown::Discount qw/markdown/;
use Time::HiRes qw/gettimeofday/;
use Redis;
use JSON::XS;
use POSIX qw/strftime/;

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub memd {
    my ($self) = @_;
    $self->{_memd} ||= Cache::Memcached::Fast->new({ servers => [ +{ address => '/tmp/memcached.sock', noreply => 1 } ] });
}

sub redis {
    my ($self) = @_;
    $self->{_redis} ||= Redis->new(sock => '/tmp/redis.sock');
} 

# proc cache
my $USERS;
my %USER_OF;
my %NAME_TO_USER;
my %USERNAME_OF;

sub user {
    my ($self, $id) = @_;
    return unless $id;
    $USERS ||= +[ map { decode_json($_) } @{$self->redis->lrange('users', 0, -1)}];
    %USER_OF = map { $_->{id} => $_ } @$USERS unless %USER_OF;
    return $USER_OF{$id};
}

sub user_by_name {
    my ($self, $name) = @_;
    return unless $name;
    $USERS ||= +[ map { decode_json($_) } @{$self->redis->lrange('users', 0, -1)}];
    %NAME_TO_USER = map { $_->{username} => $_ } @$USERS unless %NAME_TO_USER;
    return $NAME_TO_USER{$name};
}

sub username {
    my ($self, $id) = @_;
    $USERS ||= +[ map { decode_json($_) } @{$self->redis->lrange('users', 0, -1)}];
    %USERNAME_OF = map { $_->{id} => $_->{username} } @$USERS unless %USERNAME_OF;
    return $USERNAME_OF{$id};
}

filter 'session' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid = $c->req->env->{"psgix.session.options"}->{id};
        $c->stash->{session_id} = $sid;
        $c->stash->{session}    = $c->req->env->{"psgix.session"};
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;

        my $user_id = $c->req->env->{"psgix.session"}->{user_id};
        my $user = $self->user($user_id);

        $c->stash->{user} = $user;
        $c->res->header('Cache-Control', 'private') if $user;
        $app->($self, $c);
    }
};

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        unless ( $c->stash->{user} ) {
            return $c->redirect('/');
        }
        $app->($self, $c);
    };
};

filter 'anti_csrf' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid   = $c->req->param('sid');
        my $token = $c->req->env->{"psgix.session"}->{token};
        if ( $sid ne $token ) {
            return $c->halt(400);
        }
        $app->($self, $c);
    };
};

get '/signin' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    $c->render('signin.tx', {});
};

post '/signout' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    $c->req->env->{"psgix.session.options"}->{change_id} = 1;
    delete $c->req->env->{"psgix.session"}->{user_id};
    $c->redirect('/');
};

post '/signup' => [qw(session anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->user_by_name($username);
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->redis->rpush('users',+{
            id => 9999, # TODO
            username => $username,
            password => $password_hash,
            salt => $salt,
        });
        my $user_id = 9999; # TODO
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->user_by_name($username);
    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $c->req->env->{"psgix.session.options"}->{change_id} = 1;
        my $session = $c->req->env->{"psgix.session"};
        $session->{user_id} = $user->{id};
        $session->{token}   = sha256_hex(rand());
        return $c->redirect('/mypage');
    }
    else {
        $c->render('signin.tx', {});
    }
};

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $total = $self->redis->llen('public_memos');
    my $memos = $self->redis->lrange('public_memos', -100, -1);
    $memos = [ reverse map { decode_json($_) } @$memos ];
    my $res = $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
    $self->memd->set('cache_/'.$c->stash->{session_id}, $c->res->body, 1);
    return $res;
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->redis->llen('public_memos');
    my $memos = $self->redis->lrange('public_memos', $page * 100, ($page+1) * 100 -1);
    $memos = [ map { decode_json($_) } @$memos ];
    if ( @$memos == 0 ) {
        return $c->halt(404);
    }
    my $res = $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $total,
    });
    $self->memd->set('cache_/recent/'.$page.''.$c->stash->{session_id}, $c->res->body, 100);
    return $res;
};

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->redis->lrange('user_memos_'.$c->stash->{user}->{id}, 0, -1);
    $memos = [ map { decode_json($_) } @$memos ];
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $is_private = scalar($c->req->param('is_private')) ? 1 : 0;

    my $memo_id = $self->redis->incr('seq_memo');

    my $content = scalar $c->req->param('content');
    my @lines = split(/\r?\n/, $content, 2);
    my $title = $lines[0];

    my $memo = +{
        id => $memo_id,
        user => $c->stash->{user}->{id},
        content_html => markdown($content),
        is_private => $is_private,
        created_at => strftime("%Y-%m-%d %H:%M:%S",localtime),
    };
    $memo->{username} = $self->username($memo->{user});
    my $json_memo = encode_json($memo);
    $self->redis->hset('memos', $memo_id, $json_memo);

    $memo->{title} = $title;
    delete $memo->{content_html};
    $json_memo = encode_json($memo);
    $self->redis->rpush('user_memos_'.$memo->{user}, $json_memo);
    if (!$is_private) {
        $self->redis->rpush('public_memos', $json_memo);
    }

    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $memo = $self->redis->hget('memos', $c->args->{id});
    unless ($memo) {
        $c->halt(404);
    }
    $memo = decode_json($memo);
    if ($memo->{is_private} == 1) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }

    my ($newer, $older);
    my $user_memos = $self->redis->lrange('user_memos_'.$memo->{user}, 0, -1);
    $user_memos = [ map { decode_json($_) } @$user_memos ];
    unless ($user && $user->{id} == $memo->{user}) {
        $user_memos = [ grep { $_->{is_private} == 0 } @$user_memos ];
    }
    
    while (my ($i, $user_memo) = each @$user_memos) {
        if ($user_memo->{id} == $memo->{id}) {
            my $n = $i+1;
            $newer = $user_memos->[$n] if $user_memos->[$n];
            my $o = $i-1;
            $older = $user_memos->[$o] if $o >= 0;
        }
    }

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
    });
};

1;
