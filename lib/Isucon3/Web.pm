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

# memcache
my $cache = Cache::Memcached::Fast->new({
    servers => [ {address => '127.0.0.1:11212'}],
});

sub public_updated_time {
    my ($self, $update) = @_;
    my $key = "public_updated_time";
    return $cache->get($key) unless $update;
    my ($sec, $microsec) = gettimeofday;
    $cache->set($key => "$sec.$microsec");
}

sub seq_public {
    my ($self, $update) = @_;
    my $key = "seq_public";
    unless ($update) {
        my $seq_public = $cache->get($key);
        return $seq_public if $seq_public;
    }
    my $seq_public = $self->dbh->select_one(
        'SELECT id FROM seq_public'
    );
    $cache->set($key => $seq_public);
    return $seq_public;
}


# proc cache
my %USER_OF;

my $LAST_PUBLIC_MEMOS_CACHED;
my %PUBLIC_MEMOS_OF; # page => [ memo, memo,,, ]
sub get_public_memos_by_page {
    my ($self, $page) = @_;

    my $updated_time = $self->public_updated_time;
    unless ($LAST_PUBLIC_MEMOS_CACHED == $updated_time) {
        %PUBLIC_MEMOS_OF = ();
    }

    if ($LAST_PUBLIC_MEMOS_CACHED == $updated_time) {
        return $PUBLIC_MEMOS_OF{$page} if $PUBLIC_MEMOS_OF{$page};
    }
        
    my $memos = $self->dbh->select_all(
        sprintf("SELECT id, title, user, username, created_at FROM memos WHERE seq_public BETWEEN %d AND %d ORDER BY seq_public", $page * 100 + 1, ($page+1) * 100)
    );

    if (0 && $updated_time) {
        $PUBLIC_MEMOS_OF{$page} = $memos;
        $LAST_PUBLIC_MEMOS_CACHED = $updated_time;
    }
    return $memos;
}

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
        my $user = $USER_OF{$user_id} || $self->dbh->select_row(
            'SELECT * FROM users WHERE id=?',
            $user_id,
        );
        $USER_OF{$user_id} ||= $user;

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

    my $total = $self->seq_public();
    my $memos = $self->dbh->select_all(
        sprintf("SELECT id, title, user, username, created_at FROM memos WHERE seq_public > 0 ORDER BY seq_public DESC LIMIT 100")
    );
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->seq_public();
    my $memos = $self->get_public_memos_by_page($page);
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

    my $memos = $self->dbh->select_all(
        'SELECT id, title, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY id DESC',
        $c->stash->{user}->{id},
    );
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $is_private = scalar($c->req->param('is_private')) ? 1 : 0;
    my $seq_public = 0;
    if ($is_private) {
        # todo
    } else {
        $self->dbh->query("UPDATE seq_public SET id=LAST_INSERT_ID(id+1)");
        $seq_public = $self->dbh->last_insert_id;
        $self->seq_public(my $update = 1);
    }

    my $content = scalar $c->req->param('content');
    my @lines = split(/\r?\n/, $content, 2);
    my $title = $lines[0];

    $self->dbh->query(
        'INSERT INTO memos (user, username, title, content, is_private, seq_public, created_at) VALUES (?, ?, ?, ?, ?, ?, now())',
        $c->stash->{user}->{id},
        $c->stash->{user}->{username},
        $title,
        $content,
        $is_private,
        $seq_public
    );
    my $memo_id = $self->dbh->last_insert_id;
    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $memo = $self->dbh->select_row(
        'SELECT id, user, username, content, is_private, created_at, updated_at FROM memos WHERE id=?',
        $c->args->{id},
    );
    unless ($memo) {
        $c->halt(404);
    }
    if ($memo->{is_private}) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }
    $memo->{content_html} = markdown($memo->{content});

    my $cond;
    if ($user && $user->{id} == $memo->{user}) {
        $cond = "ORDER BY id";
    }
    else {
        $cond = "AND seq_public>0 ORDER BY seq_public";
    }

    my $memos = $self->dbh->select_all(
        "SELECT id FROM memos WHERE user=? $cond",
        $memo->{user},
    );
    my ($newer, $older);
    for my $i ( 0 .. scalar @$memos - 1 ) {
        if ( $memos->[$i]->{id} eq $memo->{id} ) {
            $older = $memos->[ $i - 1 ] if $i > 0;
            $newer = $memos->[ $i + 1 ] if $i < @$memos;
        }
    }

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
    });
};

1;
