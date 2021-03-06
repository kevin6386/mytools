nr=$1
e=$2
eo=$3
ns=$4
client=$5
ddir=$6
dop=$7
dlmin=$8
dlmax=$9
dokill=${10}
dname=${11}
only1t=${12}
unique=${13}
rpc=${14}
ips=${15}
nqt=${16}
setup=${17}
dbms=${18}
short=${19}
bulk=${20}
secatend=${21}
dbopt=${22}

mypy=python3

if [[ $short == "yes" ]]; then
names="--name_cash=caid --name_cust=cuid --name_ts=ts --name_price=prid --name_prod=prod"
else
names=""
fi

sfx=dop${dop}.ns${ns}

rm -f o.res.$sfx

maxr=$(( $nr / $dop ))

moauth="--authenticationDatabase admin -u root -p pw"
pgauth="--host 127.0.0.1"

if [[ $dbms == "mongo" ]]; then
  echo "no need to reset MongoDB replication as oplog is capped"
  while :; do ps aux | grep mongod | grep "\-\-config" | grep -v grep; sleep 30; done >& o.ps.$sfx &
  spid=$!
elif [[ $dbms == "mysql" ]]; then
  $client -uroot -ppw -A -h127.0.0.1 -e 'reset master'
  while :; do ps aux | grep mysqld | grep basedir | grep datadir | grep -v mysqld_safe | grep -v grep; sleep 30; done >& o.ps.$sfx &
  spid=$!
elif [[ $dbms == "postgres" ]]; then
  # TODO postgres
  echo "TODO: reset Postgres replication"
  while :; do ps aux | grep postgres | grep -v grep; sleep 30; done >& o.ps.$sfx &
  spid=$!
fi

if [[ $setup == "yes" ]] ; then
  if [[ $dbms == "mongo" ]]; then
    $client $moauth ib --eval 'db.dropDatabase()'
    # echo "show databases" | $client $moauth 
    sleep 5
    $client $moauth ib --eval 'db.createCollection("foo")'
  elif [[ $dbms == "mysql" ]]; then
    $client -uroot -ppw -A -h127.0.0.1 -e 'drop database ib'
    sleep 5
    $client -uroot -ppw -A -h127.0.0.1 -e 'create database ib'
  else
    echo "TODO: postgres"
    $client me -c 'drop database ib' $pgauth
    sleep 5
    $client me -c 'create database ib' $pgauth
  fi
fi

killall vmstat
killall iostat
killall top

$mypy mstat.py --db_user=root --db_password=pw --db_host=127.0.0.1 --loops=10000000 --interval=5 2> /dev/null > o.mstat.$sfx &
mpid=$!

vmstat 5 >& o.vm.$sfx &
vpid=$!
iostat -y -kx 5 >& o.io.$sfx &
ipid=$!
top -w 200 -c -b -d 60 >& o.top.$sfx &
tpid=$!

start_secs=$( date +%s )

for n in $( seq 1 $dop ) ; do

  if [[ $setup == "yes" ]]; then
    setstr="--setup"
  else
    setstr=""
  fi

  if [[ $only1t == "yes" && $n -gt 1 ]]; then
    setstr=""
  fi  

  if [[ $only1t == "yes" ]]; then
    tn="pi1"
  else
    tn="pi${n}"
  fi

  if [[ $dbms == "mongo" ]]; then
    db_args="--mongo_w=1 --db_user=root --db_password=pw"
  elif [[ $dbms == "mysql" ]]; then
    db_args="--db_user=root --db_password=pw --engine=$e --engine_options=$eo --unique_checks=${unique} --bulk_load=${bulk}"
  else
    db_args="--db_user=root --db_password=pw --engine=pg --engine_options=$eo --unique_checks=${unique} --bulk_load=${bulk}"
  fi

  if [[ $secatend == "yes" ]]; then
    db_args+=" --secondary_at_end"
  fi

  if [[ $ips = 0 ]] ; then
    rpr=100000
  else
    rpr=$(( ips * 10 ))
  fi

  echo iibench.py --dbms=$dbms --db_name=ib --rows_per_report=$rpr --db_host=127.0.0.1 ${db_args} --max_rows=${maxr} --table_name=${tn} $setstr --num_secondary_indexes=$ns --data_length_min=$dlmin --data_length_max=$dlmax --rows_per_commit=${rpc} --inserts_per_second=${ips} --query_threads=${nqt} --seed=$(( $start_secs + $n )) --dbopt=$dbopt $names > o.ib.dop${dop}.ns${ns}.${n} 
  /usr/bin/time -o o.ctime.${sfx}.${n} $mypy iibench.py --dbms=$dbms --db_name=ib --rows_per_report=$rpr --db_host=127.0.0.1 ${db_args} --max_rows=${maxr} --table_name=${tn} $setstr --num_secondary_indexes=$ns --data_length_min=$dlmin --data_length_max=$dlmax --rows_per_commit=${rpc} --inserts_per_second=${ips} --query_threads=${nqt} --seed=$(( $start_secs + $n )) --dbopt=$dbopt $names >> o.ib.dop${dop}.ns${ns}.${n} 2>&1 &

  pids[${n}]=$!
  
  sleep 3
 
done

for n in $( seq 1 $dop ) ; do
  # echo Wait for ${pids[${n}]} $n
  wait ${pids[${n}]} 
done

stop_secs=$( date +%s )
tot_secs=$(( $stop_secs - $start_secs ))
insert_rate=$( echo "scale=1; $nr / $tot_secs" | bc )
insert_per=$( echo "scale=1; $insert_rate / $dop" | bc )

total_query=$( for n in $( seq 1 $dop ); do awk '{ if (NF==9) print $0 }' o.ib.dop${dop}.ns${ns}.$n | tail -1 ; done | awk '{ tq += $7; } END { print tq }' )
query_rate=$( echo "scale=1; $total_query / $tot_secs" | bc )

# echo $dop processes, $maxr rows-per-process, $tot_secs seconds, $insert_rate rows-per-second, $insert_per rows-per-second-per-user
echo $dop processes, $maxr rows-per-process, $tot_secs seconds, $insert_rate rows-per-second, $insert_per rows-per-second-per-user, $total_query queries, $query_rate queries-per-second > o.res.$sfx

# Compute average rates per interval using 10 intervals
for x in 6 9 ; do
for n in $( seq 1 $dop ); do
  f=o.ib.dop${dop}.ns3.$n
  xa=$( wc -l $f | awk '{ print $1 }' ); xm=$(( $xa - 2 )); xp=$(( $xm / 10 ))
  for s in $( seq 0 9 ); do
    ha=$(( ($s * $xp) + $xp + 2 ))
    head -${ha} $f | tail -${xp} | awk '{ c += 1; s += $x } END { printf "%.0f,", s/c }' x=$x
  done
  printf "%s:DBMS\n" $n
done > o.rate.c.$x
cat o.rate.c.$x | tr ',' '\t' > o.rate.t.$x
done 

kill $mpid >& /dev/null
kill $vpid >& /dev/null
kill $ipid >& /dev/null
kill $tpid >& /dev/null
kill $spid >& /dev/null
gzip o.top.$sfx 

if [[ $dbms == "mongo" ]]; then
echo "db.serverStatus()" | $client $moauth > o.es.$sfx
echo "db.serverStatus({tcmalloc:2}).tcmalloc" | $client $moauth > o.es1.$sfx
echo "db.serverStatus({tcmalloc:2}).tcmalloc.tcmalloc.formattedString" | $client $moauth > o.es2.$sfx

for n in $( seq 1 $dop ) ; do
  echo "db.pi${n}.stats()" | $client $moauth ib > o.tab${n}.$sfx
  echo "db.pi${n}.stats({indexDetails: true})" | $client $moauth ib > o.tab${n}.id.$sfx
  echo "db.pi${n}.latencyStats({histograms: true})" | $client $moauth ib > o.tab${n}.ls.$sfx
  echo "db.pi${n}.latencyStats({histograms: true}).pretty()" | $client $moauth ib > o.tab${n}.lsp.$sfx
done

echo "db.stats()" | $client $moauth > o.dbstats.$sfx
echo "db.oplog.rs.stats()" | $client $moauth local > o.oplog.$sfx
echo "show dbs" | $client $moauth linkdb0 > o.dbs.$sfx

elif [[ $dbms == "mysql" ]]; then
$client -uroot -ppw -A -h127.0.0.1 -e 'show engine innodb status\G' > o.esi.$sfx
$client -uroot -ppw -A -h127.0.0.1 -e 'show engine rocksdb status\G' > o.esr.$sfx
$client -uroot -ppw -A -h127.0.0.1 -e 'show engine tokudb status\G' > o.est.$sfx
$client -uroot -ppw -A -h127.0.0.1 -e 'show global status' > o.gs.$sfx
$client -uroot -ppw -A -h127.0.0.1 -e 'show global variables' > o.gv.$sfx
$client -uroot -ppw -A -h127.0.0.1 -e 'show memory status\G' > o.mem.$sfx

$client -uroot -ppw -A -h127.0.0.1 ib -e 'show table status\G' > o.ts.$sfx
echo "sum of data and index length columns in GB" >> o.ts.$sfx
cat o.ts.$sfx  | grep "Data_length"  | awk '{ s += $2 } END { printf "%.3f\n", s / (1024*1024*1024) }' >> o.ts.$sfx
cat o.ts.$sfx  | grep "Index_length" | awk '{ s += $2 } END { printf "%.3f\n", s / (1024*1024*1024) }' >> o.ts.$sfx

$client -uroot -ppw -A -h127.0.0.1 -e 'reset master'

else
echo "TODO reset replication state"
$client ib -c 'show all' > o.pg.conf
$client ib -x -c 'select * from pg_stat_bgwriter' > o.pgs.bg
$client ib -x -c 'select * from pg_stat_database' > o.pgs.db
$client ib -x -c 'select * from pg_stat_all_tables' > o.pgs.tabs
$client ib -x -c 'select * from pg_stat_all_indexes' > o.pgs.idxs
$client ib -x -c 'select * from pg_statio_all_tables' > o.pgi.tabs
$client ib -x -c 'select * from pg_statio_all_indexes' > o.pgi.idxs
$client ib -x -c 'select * from pg_statio_all_sequences' > o.pgi.seq
fi

du -hs $ddir > o.sz.$sfx
echo "with apparent size " >> o.sz.$sfx
du -hs --apparent-size $ddir >> o.sz.$sfx
echo "all" >> o.sz.$sfx
du -hs ${ddir}/* >> o.sz.$sfx

ls -asShR $ddir > o.lsh.r.$sfx

ddirs=( $ddir $ddir/data $ddir/data/.rocksdb $ddir/base $ddir/global )
x=0
for xd in ${ddirs[@]}; do
  if [ -d $xd ]; then
    ls -asS --block-size=1M $xd > o.ls.${x}.$sfx
    ls -asSh $xd > o.lsh.${x}.$sfx
    x=$(( $x + 1 ))
  fi
done

cat o.ls.*.$sfx | grep -v "^total" | sort -rnk 1,1 > o.lsa.$sfx

# Old and new format for iostat output
#Device            r/s     w/s     rkB/s     wkB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util
#Device:         rrqm/s   wrqm/s     r/s     w/s    rkB/s    wkB/s avgrq-sz avgqu-sz   await r_await w_await  svctm  %util

printf "\niostat, vmstat normalized by insert rate\n" >> o.res.$sfx
printf "samp\tr/s\trkb/s\twkb/s\tr/q\trkb/q\twkb/q\tips\t\tspi\n" >> o.res.$sfx

iover=$( head -10 o.io.$sfx | grep Device | grep avgrq\-sz | wc -l )
if [[ $iover -eq 1 ]]; then
  grep $dname o.io.$sfx | awk '{ if (NR>1) { rs += $4; rkb += $6; wkb += $7; c += 1 } } END { printf "%s\t%.1f\t%.0f\t%.0f\t%.3f\t%.3f\t%.3f\t%s\t\t%.6f\n", c, rs/c, rkb/c, wkb/c, rs/c/q, rkb/c/q, wkb/c/q, q, (p*r)/q }' q=${insert_rate} p=$dop r=$rpc >> o.res.$sfx
else
  grep $dname o.io.$sfx | awk '{ if (NR>1) { rs += $2; rkb += $4; wkb += $5; c += 1 } } END { printf "%s\t%.1f\t%.0f\t%.0f\t%.3f\t%.3f\t%.3f\t%s\t\t%.6f\n", c, rs/c, rkb/c, wkb/c, rs/c/q, rkb/c/q, wkb/c/q, q, (p*r)/q }' q=${insert_rate} p=$dop r=$rpc >> o.res.$sfx
fi

printf "\nsamp\tcs/s\tcpu/c\tcs/q\tcpu/q\n" >> o.res.$sfx
grep -v swpd o.vm.$sfx | awk '{ if (NR>1) { cs += $12; cpu += $13 + $14; c += 1 } } END { printf "%s\t%.0f\t%.1f\t%.3f\t%.6f\n", c, cs/c, cpu/c, cs/c/q, cpu/c/q }' q=${insert_rate} >> o.res.$sfx

printf "\niostat, vmstat normalized by query rate\n" >> o.res.$sfx
printf "samp\tr/s\trkb/s\twkb/s\tr/q\trkb/q\twkb/q\tqps\t\tspq\n" >> o.res.$sfx
if [[ $iover -eq 1 ]]; then
  grep $dname o.io.$sfx | awk '{ if (NR>1) { rs += $4; rkb += $6; wkb += $7; c += 1 } } END { printf "%s\t%.1f\t%.0f\t%.0f\t%.3f\t%.3f\t%.3f\t%s\t\t%.6f\n", c, rs/c, rkb/c, wkb/c, rs/c/q, rkb/c/q, wkb/c/q, q, (p*r)/q }' q=${query_rate} p=$dop r=$rpc >> o.res.$sfx
else
  grep $dname o.io.$sfx | awk '{ if (NR>1) { rs += $2; rkb += $4; wkb += $5; c += 1 } } END { printf "%s\t%.1f\t%.0f\t%.0f\t%.3f\t%.3f\t%.3f\t%s\t\t%.6f\n", c, rs/c, rkb/c, wkb/c, rs/c/q, rkb/c/q, wkb/c/q, q, (p*r)/q }' q=${query_rate} p=$dop r=$rpc >> o.res.$sfx
fi

printf "\nsamp\tcs/s\tcpu/c\tcs/q\tcpu/q\n" >> o.res.$sfx
grep -v swpd o.vm.$sfx | awk '{ if (NR>1) { cs += $12; cpu += $13 + $14; c += 1 } } END { printf "%s\t%.0f\t%.1f\t%.3f\t%.6f\n", c, cs/c, cpu/c, cs/c/q, cpu/c/q }' q=${query_rate} >> o.res.$sfx

echo >> o.res.$sfx
du -hs $ddir >> o.res.$sfx

echo >> o.res.$sfx
ps auxww | grep mysqld | grep -v mysqld_safe | grep -v grep >> o.res.$sfx
ps aux | grep mongod | grep -v grep >> o.res.$sfx

echo >> o.res.$sfx
echo "Max insert" >> o.res.$sfx
grep -h "Insert rt" o.ib.dop${dop}.ns${ns}.* | grep -v max | awk '{ printf "%.3f\n", $13 }' | sort -rnk 1 | head -3 >> o.res.$sfx
echo "Max query" >> o.res.$sfx
grep -h "Query rt" o.ib.dop${dop}.ns${ns}.* | grep -v max | awk '{ printf "%.3f\n", $13 }' | sort -rnk 1 | head -3 >> o.res.$sfx

echo >> o.res.$sfx
for n in $( seq 1 $dop ) ; do
  grep "Insert rt" o.ib.dop${dop}.ns${ns}.${n} >> o.res.$sfx
done

echo >> o.res.$sfx
for n in $( seq 1 $dop ) ; do
  grep "Query rt" o.ib.dop${dop}.ns${ns}.${n} >> o.res.$sfx
done

printf "\ninsert and query rate at nth percentile\n" >> o.res.$sfx
for n in $( seq 1 $dop ) ; do
  lines=$( awk '{ if (NF == 9) { print $6 } }' o.ib.dop${dop}.ns${ns}.${n} | wc -l )
  for x in 50 75 90 95 99 ; do
    off=$( printf "%.0f" $( echo "scale=3; ($x / 100.0 ) * $lines " | bc ) )
    i_nth=$( grep -v "Insert rt" o.ib.dop${dop}.ns${ns}.$n | grep -v "Query rt" | grep -v total_seconds | awk '{ if (NF == 9) { print $6 } }' | sort -rnk 1,1 | head -${off} | tail -1 )
    q_nth=$( grep -v "Insert rt" o.ib.dop${dop}.ns${ns}.$n | grep -v "Query rt" | grep -v total_seconds | awk '{ if (NF == 9) { print $9 } }' | sort -rnk 1,1 | head -${off} | tail -1 )
    echo ${x}th, ${off} / ${lines} = $i_nth insert, $q_nth query >> o.res.$sfx
  done
done

echo >> o.res.$sfx
echo "CPU seconds" >> o.res.$sfx

# Client CPU seconds
cat o.ctime.${sfx}.* | head -1 | awk '{ print $1 }' | sed 's/user//g' > o.utime.$sfx
cat o.ctime.${sfx}.* | head -1 | awk '{ print $2 }' | sed 's/system//g' > o.stime.$sfx
paste o.utime.$sfx o.stime.$sfx > o.atime.$sfx
us=$( cat o.atime.$sfx | awk '{ s += $1 } END { printf "%.2f\n", s }' )
sy=$( cat o.atime.$sfx | awk '{ s += $2 } END { printf "%.2f\n", s }' )
echo "client: $us user, $sy system, $( echo "$us $sy" | awk '{ printf "%.1f", $1 + $2 }' ) total" >> o.res.$sfx

function dt2s {
  ts=$1
  min=$( echo $ts | tr ':' ' ' | awk '{ print $1 }' )
  sec=$( echo $ts | tr ':' ' ' | awk '{ print $2 }' )
  d2nsecs=$( echo "$min * 60 + $sec" | bc )
  echo $d2nsecs
}

# dbms CPU seconds
# TODO -- make this work for postgres which uses many processes
dh=$( cat o.ps.$sfx | head -1 | awk '{ print $10 }' )
dt=$( cat o.ps.$sfx | tail -1 | awk '{ print $10 }' )
hsec=$( dt2s $dh )
tsec=$( dt2s $dt )
dsec=$( echo "$hsec $tsec" | awk '{ printf "%.1f", $2 - $1 }' )
dsec0=$( echo "$hsec $tsec" | awk '{ printf "%.0f", $2 - $1 }' )
echo "dbms: $dsec" >> o.res.$sfx

cat o.res.$sfx
