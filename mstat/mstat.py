#!/usr/bin/python3
#
# Copyright (C) 2009 Google Inc.
# Copyright (C) 2009 Facebook Inc.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Originally published by Google.
# Additional improvements from Facebook.
#

"""Multiple-stat reporter

This gathers performance statistics from multiple data sources and reports
them over the same interval. It supports iostat and vmstat on modern Linux
distributions and SHOW GLOBAL STATUS output from MySQL. It is a convenient way
to collect data during benchmarks and can perform some computations on the
collected data including 'rate', 'avg' and 'max'. It can also aggregate
data from multiple devices from iostat.

This reports all data from vmstat, iostat and SHOW GLOBAL STATUS as counters
and as rates. Other stats can be derived from them and defined on the command
line or via file named by the --sources option.

Run it like:
  mstat.py --loops 1000000 --interval 60
"""

__author__ = 'Mark Callaghan (mdcallag@gmail.com)'

import itertools
import optparse
import subprocess
import sys
import time

import MySQLdb

class MyIterable:
  def __iter__(self):
    return self

class Timestamper(MyIterable):
  def __next__(self):
    return time.strftime('%Y-%m-%d_%H:%M:%S')

  next = __next__

class Counter(MyIterable):
  def __init__(self, interval):
    self.interval = interval
    self.value = 0

  def __next__(self):
    result = str(self.value)
    self.value += self.interval
    return result

  next = __next__

class ScanMysql(MyIterable):
  def __init__(self, db_user, db_password, db_host, db_name, sql, retries,
               err_data):
    self.db_user = db_user
    self.db_password = db_password
    self.db_host = db_host
    self.db_name = db_name
    self.sql = sql
    self.retries = retries
    self.err_data = err_data

  def __next__(self):
    r = self.retries
    while r >= 0:
      connect = None
      try:
        connect = MySQLdb.connect(host=self.db_host, user=self.db_user,
                                  passwd=self.db_password,
                                  db = self.db_name)
        cursor = connect.cursor()
        cursor.execute(self.sql)
        result = []
        for row in cursor.fetchall():
          result.append(' '.join(row))
        connect.close()
        # print 'Connectdb'
        if result:
          return '\n'.join(result)
        else:
          return self.err_data
      except MySQLdb.Error as e:
        print('sql (%s) fails (%s)' % (self.sql, e))
        if connect is not None:
          try:
            connect.close()
          except MySQLdb.Error:
            pass
        time.sleep(0.1)
      r -= 1
    return self.err_data

  next = __next__

class ScanFork(MyIterable):
  def __init__(self, cmdline, skiplines):
    self.proc = subprocess.Popen(cmdline, shell=True, bufsize=1,
                                 universal_newlines=True,                                
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
    self.cmdline = cmdline
    self.lines_to_skip = skiplines
    sys.stderr.write("forked pid %d for (%s)\n" % (self.proc.pid, cmdline))
    sys.stderr.flush()

  def __next__(self):
    while True:
      line = self.proc.stdout.readline()
      if not line:
        raise StopIteration
      elif self.lines_to_skip > 0:
        self.lines_to_skip -= 1
        continue
      else:
        return line

  next = __next__

class FilterEquals(MyIterable):
  def __init__(self, pos, value, iterable, iostat_hack=False):
    self.pos = pos
    self.value = value
    self.iter = iterable
    self.iostat_hack = iostat_hack

  def __next__(self):
    while True:
      lines = next(self.iter)
      for line in lines.split('\n'):
        cols = line.split()
        if len(cols) >= (self.pos + 1) and cols[self.pos] == self.value:
          return line
        # Ugly hack for long device name split over 2 lines
        # elif self.iostat_hack and len(cols) == 1 and cols[self.pos] == self.value:
        # return '%s %s' % (self.value, next(self.iter)

  next = __next__

class Project(MyIterable):
  def  __init__(self, pos, iterable):
    self.pos = pos
    self.iter = iter(iterable)

  def __next__(self):
    line = next(self.iter)
    cols = line.split()
    try:
      v = float(cols[self.pos])
      return cols[self.pos]
    except ValueError:
      return 0.0

  next = __next__

class ExprAbsToRel(MyIterable):
  def __init__(self, interval, iterable):
    self.interval = interval
    self.iter = iter(iterable)
    self.prev = None

  def __next__(self):
    current = float(next(self.iter))
    if self.prev is None:
      self.prev = current
      return '0'
    else:
      diff = current - self.prev
      rate = diff / self.interval
      self.prev = current
      return str(rate)

  next = __next__

class ExprFunc(MyIterable):
  def __init__(self, func, iterables):
    self.func = func
    self.iters = [iter(i) for i in iterables]

  def __next__(self):
    return str(self.func([float(i.next()) for i in self.iters]))

  next = __next__

class ExprAvg(MyIterable):
  def __init__(self, iterables):
    self.iters = [iter(i) for i in iterables]

  def __next__(self):
    return str(sum([float(i.next()) for i in self.iters]) / len(self.iters))

  next = __next__

vmstat_cols = { 'swpd':2, 'free':3, 'buff':4, 'cache':5, 'si':6, 'so':7,
                'bi':8, 'bo':9, 'in':10, 'cs':11, 'us':12, 'sy':13,
                'id':14, 'wa':15 }

# Initialized in iostat_init
iostat_cols = { }

agg_funcs = [ 'sum', 'rate', 'ratesum', 'max', 'avg' ]

# Iostat output...
# Old style
#    Device:         rrqm/s   wrqm/s     r/s     w/s    rkB/s    wkB/s avgrq-sz avgqu-sz   await r_await w_await  svctm  %util
# New style
#    Device            r/s     w/s     rkB/s     wkB/s   rrqm/s   wrqm/s  %rrqm  %wrqm r_await w_await aqu-sz rareq-sz wareq-sz  svctm  %util

def iostat_init():
  scan_iostat = ScanFork('iostat -kx 1 1', 0)
  saw_device = False
  devices = []
  global iostat_cols
  iostat_cols = {}
  for line in scan_iostat:
    if line.startswith('Device'):
      cols = line.split()
      for idx, c in enumerate(cols[1:]):
        iostat_cols[c] = idx+1
      saw_device = True
    elif saw_device:
      cols = line.split()
      if cols:
        devices.append(cols[0])
  #print('iostat devices: %s' % devices)
  #print('iostat columns: %s' % iostat_cols)
  return devices

def get_matched_devices(prefix, devices):
  assert prefix[-1] == '*'
  matched = []
  for d in devices:
    if d.startswith(prefix[:-1]) and len(d) > len(prefix[:-1]):
      matched.append(d)
  return matched

def get_my_cols(db_user, db_password, db_host, db_name):
  names = []
  try:
    connect = MySQLdb.connect(host=db_host, user=db_user, passwd=db_password,
                              db=db_name)
    cursor = connect.cursor()
    cursor.execute('SHOW GLOBAL STATUS')
    for row in cursor.fetchall():
      if len(row) == 2:
        try:
          v = float(row[1])
          names.append(row[0])
        except ValueError:
          pass
    connect.close()
    return names
  except MySQLdb.Error as e:
    print('SHOW GLOBAL STATUS fails:', e)
    return []

def parse_args(arg, counters, expanded_args, devices):
  # print 'parse_args(%s)' % arg
  parts = arg.split('.')
  pix = 0
  pend = len(parts)
  use_agg = False
  expand = False
  ignore = False

  if parts[pix] in agg_funcs:
    pix += 1
    use_agg = True

  while pix != pend:
    if parts[pix] == 'timer':
      pix += 1
      assert pix == pend
    elif parts[pix] == 'timestamp':
      pix += 1
      assert pix == pend
    elif parts[pix] == 'counter':
      pix += 1
      assert pix == pend
    elif parts[pix] == 'vmstat':
      assert pend - pix >= 2
      assert parts[pix+1] in vmstat_cols
      counters['vmstat'] += 1
      pix += 2
    elif parts[pix] == 'iostat':
      assert pend - pix >= 3
      assert parts[pix+2] in iostat_cols

      if parts[pix+1][-1] == '*':
        assert pix + 3 == pend
        if use_agg:
          assert pix == 1
          expand = True
        else:
          assert pix == 0
          expand = True
      else:
        if parts[pix+1] in devices:
          counters['iostat'] += 1
        else:
          ignore = True
      pix += 3
    elif parts[pix] == 'my':
      assert parts[pix+1] == 'status'
      assert pend - pix >= 3
      counters['my.status'] += 1
      pix += 3
    else:
      # print 'pix %d, pend %d, parts :: %s' % (pix, pend, parts)
      assert False

  if expand:
    if use_agg:
      new_parts = [parts[0]]
      matched = get_matched_devices(parts[2], devices)
      if matched:
        counters['iostat'] += len(matched)
        for m in matched:
          new_parts.extend([parts[1], m, parts[3]])
        expanded_args.append('.'.join(new_parts))
    else:
      matched = get_matched_devices(parts[1], devices)
      if matched:
        counters['iostat'] += len(matched)
        for m in matched:
          expanded_args.append('.'.join([parts[0], m, parts[2]]))
  elif not ignore:
    expanded_args.append(arg)
  else:
    print('Ignoring %s' % arg)

def make_data_inputs(arg, inputs, counters, interval, db_user,
                     db_password, db_host, db_name, db_retries,
                     tee_vmstat, tee_iostat, tee_mystat):
  parts = arg.split('.')
  pix = 0
  pend = len(parts)
  use_agg = None

  if parts[pix] in agg_funcs:
    use_agg = parts[pix]
    pix += 1

  sources = []
  while pix != pend:
    if parts[pix] == 'timer':
      sources.append((arg, Counter(interval)))
      pix += 1
    elif parts[pix] == 'timestamp':
      sources.append((arg, Timestamper()))
      pix += 1
    elif parts[pix] == 'counter':
      sources.append((arg, Counter(1)))
      pix += 1
    elif parts[pix] == 'vmstat':
      sources.append((arg, Project(vmstat_cols[parts[pix+1]],
                                   tee_vmstat[counters['vmstat']])))
      counters['vmstat'] += 1
      pix += 2
    elif parts[pix] == 'iostat':
      f = FilterEquals(0, parts[pix+1], tee_iostat[counters['iostat']], True)
      sources.append((arg, Project(iostat_cols[parts[pix+2]], f)))
      counters['iostat'] += 1
      pix += 3
    elif parts[pix] == 'my':
      assert parts[pix+1] == 'status'
      # print 'use my.status tee %d for %s' % (counters['my.status'], arg)
      f = FilterEquals(0, parts[pix+2], tee_mystat[counters['my.status']], True)
      sources.append((arg, Project(1, f)))
      counters['my.status'] += 1
      pix += 3
    else:
      assert False

  if use_agg is None:
    assert len(sources) == 1
    inputs.append(sources[0])
  elif use_agg == 'rate':
    assert len(sources) == 1
    inputs.append((arg, ExprAbsToRel(interval, sources[0][1])))
  elif use_agg == 'sum':
    assert len(sources) >= 1
    inputs.append((arg, ExprFunc(sum, [s[1] for s in sources])))
  elif use_agg == 'ratesum':
    assert len(sources) >= 1
    sum_iter = ExprFunc(sum, [s[1] for s in sources])
    inputs.append((arg, ExprAbsToRel(interval, sum_iter)))
  elif use_agg == 'avg':
    assert len(sources) >= 1
    inputs.append((arg, ExprAvg([s[1] for s in sources])))
  elif use_agg == 'max':
    assert len(sources) >= 1
    inputs.append((arg, ExprFunc(max, [s[1] for s in sources])))
  else:
    assert False

def build_inputs(args, interval, loops, db_user, db_password, db_host,
                 db_name, db_retries, data_sources):
  scan_vmstat = None
  scan_iostat = None
  inputs = []
  devices = iostat_init()

  parse_counters = { 'iostat' : 0, 'vmstat' : 0, 'my.status' : 0 }

  if data_sources:
    f = open(data_sources)
    args.extend([l[:-1] for l in f.xreadlines()])

  expanded_args = []

  for arg in ['timestamp', 'timer', 'counter']:
    parse_args(arg, parse_counters, expanded_args, devices)

  for dev in devices:
   for col in iostat_cols:
     parse_args('iostat.%s.%s' % (dev, col), parse_counters, expanded_args, devices)
     parse_args('rate.iostat.%s.%s' % (dev, col), parse_counters, expanded_args, devices)

  for col in vmstat_cols:
    parse_args('vmstat.%s' % col, parse_counters, expanded_args, devices)
    parse_args('rate.vmstat.%s' % col, parse_counters, expanded_args, devices)

  for col in get_my_cols(db_user, db_password, db_host, db_name):
    parse_args('my.status.%s' % col, parse_counters, expanded_args, devices)
    parse_args('rate.my.status.%s' % col, parse_counters, expanded_args, devices)

  for arg in args:
    parse_args(arg, parse_counters, expanded_args, devices)

  tee_vmstat, tee_iostat, tee_mystat = None, None, None

  if parse_counters['vmstat']:
    scan_vmstat = ScanFork('vmstat -n %d %d' % (interval, loops+1), 2)
    tee_vmstat = itertools.tee(scan_vmstat, parse_counters['vmstat'])

  if parse_counters['iostat']:
    scan_iostat = ScanFork('iostat -y -kx %d %d' % (interval, loops+1), 0)
    tee_iostat = itertools.tee(scan_iostat, parse_counters['iostat'])

  if parse_counters['my.status']:
    scan_mystat = ScanMysql(db_user, db_password, db_host, db_name,
                            'SHOW GLOBAL STATUS', db_retries, 'Foo 0')
    tee_mystat = itertools.tee(scan_mystat, parse_counters['my.status'])

  # print expanded_args

  source_counters = { 'iostat' : 0, 'vmstat' : 0, 'my.status' : 0 }
  for arg in expanded_args:
    make_data_inputs(arg, inputs, source_counters, interval, db_user,
                     db_password, db_host, db_name, db_retries,
                     tee_vmstat, tee_iostat, tee_mystat)

  return inputs

def parse_opts(args):
  parser = optparse.OptionParser()
  parser.add_option("--db_user", action="store",
                    type="string",dest="db_user",
                    default="root",
                    help="Username for database")
  parser.add_option("--db_password", action="store",
                    type="string",dest="db_password",
                    default="",
                    help="Password for database")
  parser.add_option("--db_host", action="store",
                    type="string",dest="db_host",
                    default="localhost",
                    help="Hostname for database")
  parser.add_option("--db_name", action="store",
                    type="string",dest="db_name",
                    default="test",
                    help="Database name")
  parser.add_option("--db_retries", action="store",
                    type="int",dest="db_retries",
                    default="3",
                    help="Number of times to retry failed queries")
  parser.add_option("--sources", action="store",
                    type="string",dest="data_sources",
                    default="",
                    help="File that lists data sources to plot in addition"
                    "to those listed on the command line")
  parser.add_option("--interval", action="store",
                    type="int", dest="interval",
                    default="10",
                    help="Report every interval seconds")
  parser.add_option("--loops", action="store",
                    type="int", dest="loops",
                    default="10",
                    help="Stop after this number of intervals")
  return parser.parse_args(args)

def main(argv=None):
  if argv is None:
    argv = sys.argv
  options, args = parse_opts(argv[1:])

  inputs = build_inputs(args, options.interval, options.loops,
                        options.db_user, options.db_password,
                        options.db_host, options.db_name, options.db_retries,
                        options.data_sources)
  for i,v in enumerate(inputs):
    print(i+1, v[0])

  print('START')

  iters = [iter(i[1]) for i in inputs]
  try:
    for x in range(options.loops):
      print(' '.join([i.next() for i in iters]))
      time.sleep(options.interval)
  except StopIteration:
    pass

if __name__ == "__main__":
    sys.exit(main())
