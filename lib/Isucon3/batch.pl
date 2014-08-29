use strict;
use warnings;
use utf8;
use Cache::Memcached::Fast;
use DBIx::Sunny;

my $start = time();

my $dbh = DBIx::Sunny->connect( "dbi:mysql:database=isucon",
                                "root",
                                "root",
                                {
                                    RaiseError => 1,
                                    PrintError => 0,
                                    AutoInactiveDestroy => 1,
                                    mysql_enable_utf8 => 1,
                                    mysql_auto_reconnect => 1,
                                }
                            );

my $cache = Cache::Memcached::Fast->new({
    servers => [ {address => '127.0.0.1:11212'}],
});

sub d { use Data::Dumper; print Dumper(@_); }

$dbh->query("ALTER TABLE memos ENGINE MyISAM");
$dbh->query("ALTER TABLE memos ADD seq_public INT(11) NOT NULL");
$dbh->query("ALTER TABLE memos ADD title VARCHAR(255) NOT NULL");
$dbh->query("ALTER TABLE memos ADD INDEX i1 (seq_public)");
$dbh->query("ALTER TABLE memos ADD INDEX i2 (user, id)");
my $seq_public = 0;
$dbh->query("UPDATE seq_public SET id=?", $seq_public);

my $memos = $dbh->select_all("SELECT id, is_private, content FROM memos ORDER BY id");
for my $memo (@$memos) {
    my $title = (split(/\r?\n/, $memo->{content}, 2))[0];
    
    if (!$memo->{is_private}) {
        $seq_public++;
        print "$seq_public\n";
        $dbh->query("UPDATE memos SET title=?, seq_public=? WHERE id=?", $title, $seq_public, $memo->{id});
    } else {
        $dbh->query("UPDATE memos SET title=? WHERE id=?", $title, $memo->{id});
    }
}

$dbh->query("UPDATE seq_public SET id=?", $seq_public);
$cache->set("seq_public" => $seq_public);

my $elapsed_time = time()-$start;
print scalar(@$memos)."memos update done ($elapsed_time sec)\n";
