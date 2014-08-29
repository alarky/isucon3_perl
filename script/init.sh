#!/bin/sh
. /home/isucon/env.sh
cd /home/isucon/webapp/perl;
/home/isucon/local/perl-5.18/bin/carton exec perl /home/isucon/webapp/perl/script/initialize.pl >> /tmp/initialize.log 2>&1
