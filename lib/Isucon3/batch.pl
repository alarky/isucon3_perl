use strict;
use warnings;
use utf8;
use DBIx::Sunny;

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

sub d { use Data::Dumper; print Dumper(@_); }

my $users = $dbh->select_all("SELECT * FROM users");
my %NAME_OF = map { $_->{id} => $_->{username} } @{$users};

my $memos = $dbh->select_all("SELECT * FROM memos ORDER BY id");

my $seq_public = $dbh->select_one("SELECT id FROM seq_public");
for my $memo (@$memos) {
    if (!$memo->{is_private} && !$memo->{seq_public}) {
        $seq_public++;
        print "$seq_public\n";
        $dbh->query("UPDATE memos SET seq_public=? WHERE id=?", $seq_public, $memo->{id});
    } 

    unless ($memo->{title}) {
        my @lines = split(/\r?\n/, $memo->{content}, 2);
        my $title = $lines[0];
        $dbh->query("UPDATE memos SET title=? WHERE id=?", $title, $memo->{id});
    }

    unless ($memo->{username}) {
        $dbh->query("UPDATE memos SET username=? WHERE id=?", $NAME_OF{$memo->{user}}, $memo->{id});
    }
        
}

$dbh->query("UPDATE seq_public SET id=?", $seq_public);
