#!/usr/bin/env python

import sys, locale, tarfile, re, json, StringIO
from itertools import izip

encoding = locale.getpreferredencoding()

oid = None
oidre = None
nid = None
metadata = None

def replaceName(member):
  if oidre.match(member.name) is None:
    return False

  member.name = nid + member.name[len(oid):]
  return True

def filterMember(tar, member):
  try:
    f = tar.extractfile(member)
  except:
    replaceName(member)
    return None

  if not replaceName(member):
    return f

  if not (member.isreg() and member.name[len(nid):] == '/json'):
    return f

  buf = f.read()

  try:
    data = json.loads(buf)
    if data.get('id', '').lower() == oid:
      data.update(metadata)
      data['id'] = nid
    buf = json.dumps(data, separators=(',', ':'))
    #sys.stderr.write(json.dumps(data, indent=2, separators=(', ', ': ')))
    #sys.stderr.write('\n')
    member.size = len(buf)
  except:
    pass

  return StringIO.StringIO(buf)

def checkImageId(iid):
  iid = iid.decode(encoding)
  if re.search(r"^[0-9a-f]{64}$", iid, re.I) is None:
    sys.exit('Invalid image ID: ' + iid)
  return iid.lower()

def getMetadataDict(args):
  i = iter(args)
  return dict((k.decode(encoding), v.decode(encoding)) for (k, v) in izip(i, i))


# main Main MAIN
if len(sys.argv) < 3 or len(sys.argv) & 1 == 0:
  sys.exit(
    'Expected two or more argument - the old & new image IDs and the image metadata key, value pairs, got: ' +
    ', '.join(['<%s>' % a for a in sys.argv[1:]])
  )

oid = checkImageId(sys.argv[1])
oidre = re.compile(oid + '(/|$)', re.I)
nid = checkImageId(sys.argv[2])
metadata = getMetadataDict(sys.argv[3:])

try:
  outtar = tarfile.open(fileobj=sys.stdout, mode='w|')
  intar = tarfile.open(fileobj=sys.stdin, mode='r|*')

  while True:
    member = intar.next()
    if member is None:
      break
    f = filterMember(intar, member)
    outtar.addfile(member, fileobj=f)

finally:
  intar.close()
  outtar.close()
