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

# memcache
my $cache = Cache::Memcached::Fast->new({
    servers => [ {address => '127.0.0.1:11212'}],
});

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

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        DBIx::Sunny->connect(
            "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

sub redis {
    my ($self) = @_;
    $self->{_redis} ||= Redis->new;
}

# proc cache
my $USERS;
my %USER_OF;
my %USERNAME_OF;

sub user {
    my ($self, $id) = @_;
    return unless $id;
    $USERS ||= $self->dbh->select_all("SELECT * FROM users");
    %USER_OF = map { $_->{id} => $_ } @$USERS unless %USER_OF;
    return $USER_OF{$id};
}

sub username {
    my ($self, $id) = @_;
    $USERS ||= $self->dbh->select_all("SELECT * FROM users");
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
        my $user = $self->user($user_id) || $self->dbh->select_row(
            'SELECT * FROM users WHERE id=?',
            $user_id,
        );

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

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $total = $self->redis->llen('public_memos');
    my $memos = $self->redis->lrange('public_memos', -100, -1);
    $memos = [ reverse map { decode_json($_) } @$memos ];
    $_->{username} = $self->username($_->{user}) for @$memos;
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->redis->llen('public_memos');
    my $memos = $self->redis->lrange('public_memos', $page * 100, ($page+1) * 100 -1);
    $memos = [ map { decode_json($_) } @$memos ];
    $_->{username} = $self->username($_->{user}) for @$memos;
    if ( @$memos == 0 ) {
        return $c->halt(404);
    }
    $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $total,
    });
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
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->dbh->query(
            'INSERT INTO users (username, password, salt) VALUES (?, ?, ?)',
            $username, $password_hash, $salt,
        );
        my $user_id = $self->dbh->last_insert_id;
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
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

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->redis->lrange('user_memos_'.$c->stash->{user}->{id}, 0, -1);
    $memos = [ map { decode_json($_) } @$memos ];
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $is_private = scalar($c->req->param('is_private')) ? 1 : 0;

    $self->redis->multi;
    $self->dbh->query("UPDATE seq_memo SET id=LAST_INSERT_ID(id+1)");
    my $memo_id = $self->dbh->last_insert_id;
    $self->redis->set('seq_memo', $memo_id);

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
    my $json_memo = encode_json($memo);
    $self->redis->hset('memos', $memo_id, $json_memo);

    $memo->{title} = $title;
    delete $memo->{content_html};
    $json_memo = encode_json($memo);
    $self->redis->rpush('user_memos_'.$memo->{user}, $json_memo);
    if (!$is_private) {
        $self->redis->rpush('public_memos', $json_memo);
    }
    $self->redis->exec;

    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    unless ($self->redis->hexists('memos', $c->args->{id})) {
        $c->halt(404);
    }
    my $memo = $self->redis->hget('memos', $c->args->{id});
    unless ($memo) {
        $c->halt(500);
    }
    $memo = decode_json($memo);
    if ($memo->{is_private} == 1) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }
    $memo->{username} = $self->username($memo->{user});

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
