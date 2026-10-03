#!/usr/bin/env python3
"""
graft_apk.py v2 - additive merge of Infinity X into crDroid. crDroid's originals are never overwritten.

Settings / SystemUI (merge-missing):
  * classes that exist only in Infinity X          -> added
  * classes in both, but IX has extra methods /
    fields / interfaces crDroid lacks              -> ONLY those members are appended; crDroid's
                                                      own methods/fields stay untouched
  * resources / values / declare-styleable attrs    -> added only when crDroid lacks them
  * res/xml, layout, menu, navigation that exist in
    both but differ                                 -> crDroid's stays; IX's copy is saved as
                                                      ix_<name> and IX's code is remapped to it
                                                      (separate IX / crDroid screens)
  * preference screens shared by both               -> IX-only prefs go into an "Infinity X" category
  * manifest components / permissions               -> added only when missing

Framework (--framework add):
  framework classes / methods / fields that IX code references but crDroid's framework lacks are
  copied into crDroid's framework jars (transitively, a few rounds). Existing framework code stays.
  Stale boot images are deleted so ART regenerates them on first boot.

Compatibility is deliberately NOT a gate. The only safety nets: (1) the framework step above,
(2) --guard on hides manifest/preference entry points whose class still references something
missing, (3) any failure keeps the stock crDroid file. The script never aborts the build.
"""
import argparse, glob, os, re, shutil, struct, subprocess, sys, zipfile
from collections import defaultdict
import xml.etree.ElementTree as ET

NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", NS)
ET.register_namespace("app", "http://schemas.android.com/apk/res-auto")
ET.register_namespace("tools", "http://schemas.android.com/tools")
A = "{%s}" % NS
REF = re.compile(r'(L[\w/$]+;)->([^\s(:]+)(\([^)\s]*\)[\w/$;\[]+|:[\w/$;\[]+)')
CLS = re.compile(r'L[\w/$]+;')
HEX = re.compile(r'0x7f[0-9a-f]{6}')
MB, ME = "# ix-graft-begin\n", "# ix-graft-end\n"
RENAME_TYPES = {"xml", "layout", "menu", "navigation", "drawable"}
REPORT = []


def log(msg):
    print(msg, flush=True)
    REPORT.append(msg)


def sh(*cmd, **kw):
    return subprocess.run(list(cmd), check=True, **kw)


# ------------------------------------------------------------------ dex parsing
def _uleb(b, p):
    r = s = 0
    while True:
        x = b[p]; p += 1
        r |= (x & 0x7F) << s; s += 7
        if not x & 0x80:
            return r, p


def dex_info(data):
    """-> (defined classes, defined members, all referenced members)"""
    u32 = lambda o: struct.unpack_from("<I", data, o)[0]
    u16 = lambda o: struct.unpack_from("<H", data, o)[0]
    ss, so = u32(0x38), u32(0x3C); ts, to = u32(0x40), u32(0x44)
    po = u32(0x4C); fs, fo = u32(0x50), u32(0x54)
    ms, mo = u32(0x58), u32(0x5C); cs, co = u32(0x60), u32(0x64)
    strs = []
    for i in range(ss):
        _, p = _uleb(data, u32(so + 4 * i))
        strs.append(data[p:data.index(b"\0", p)].decode("utf-8", "replace"))
    types = [strs[u32(to + 4 * i)] for i in range(ts)]
    protos = {}

    def proto(i):
        if i not in protos:
            b = po + 12 * i; off = u32(b + 8); params = ""
            if off:
                params = "".join(types[u16(off + 4 + 2 * j)] for j in range(u32(off)))
            protos[i] = "(%s)%s" % (params, types[u32(b + 4)])
        return protos[i]

    fstr = ["%s->%s:%s" % (types[u16(fo + 8 * i)], strs[u32(fo + 8 * i + 4)], types[u16(fo + 8 * i + 2)]) for i in range(fs)]
    mstr = ["%s->%s%s" % (types[u16(mo + 8 * i)], strs[u32(mo + 8 * i + 4)], proto(u16(mo + 8 * i + 2))) for i in range(ms)]
    defined = set(); dmem = set()
    for i in range(cs):
        b = co + 32 * i
        defined.add(types[u32(b)])
        cd = u32(b + 24)
        if not cd:
            continue
        sf, p = _uleb(data, cd); inf, p = _uleb(data, p); dm, p = _uleb(data, p); vm, p = _uleb(data, p)
        for cnt in (sf, inf):
            idx = 0
            for _ in range(cnt):
                d, p = _uleb(data, p); _, p = _uleb(data, p); idx += d; dmem.add(fstr[idx])
        for cnt in (dm, vm):
            idx = 0
            for _ in range(cnt):
                d, p = _uleb(data, p); _, p = _uleb(data, p); _, p = _uleb(data, p); idx += d; dmem.add(mstr[idx])
    return defined, dmem, set(fstr) | set(mstr)


def dex_of_zip(path):
    d, m, r = set(), set(), set()
    try:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if re.fullmatch(r"classes\d*\.dex", n):
                    a, b, c = dex_info(z.read(n)); d |= a; m |= b; r |= c
    except Exception as e:
        log("  (could not read dex of %s: %s)" % (path, e))
    return d, m, r


class Framework:
    """Class/member sets of both ROMs' framework jars."""
    def __init__(self, ix_dir, cr_dir):
        self.ixc, self.ixm, self.ix_jar = self._load(ix_dir)
        self.crc, self.crm, self.cr_jar = self._load(cr_dir)
        self._ixm_by = None
        log("framework classes: infinityx=%d crdroid=%d" % (len(self.ixc), len(self.crc)))

    @staticmethod
    def _load(d):
        c, m, own = set(), set(), {}
        for j in sorted(glob.glob(os.path.join(d, "*.jar"))):
            a, b, _ = dex_of_zip(j); c |= a; m |= b
            for k in a:
                own.setdefault(k, os.path.basename(j))
        return c, m, own

    def missing(self, refs):
        bad = set()
        for r in refs:
            cls = r.split("->")[0]
            if cls in self.ixc and (cls not in self.crc or (r in self.ixm and r not in self.crm)):
                bad.add(r)
        return bad

    def ix_members_of(self, cls):
        if self._ixm_by is None:
            self._ixm_by = defaultdict(set)
            for m in self.ixm:
                self._ixm_by[m.split("->")[0]].add(m)
        return self._ixm_by.get(cls, set())


# ------------------------------------------------------------------ apktool helpers
def apktool(a, *args):
    sh("java", "-Xmx4g", "-jar", a.apktool, *args, stdout=subprocess.DEVNULL)


def install_frames(a, fw_dir, out):
    os.makedirs(out, exist_ok=True)
    for apk in glob.glob(os.path.join(fw_dir, "*res.apk")):
        try:
            apktool(a, "if", "-p", out, apk)
        except Exception as e:
            log("  framework install failed for %s: %s" % (apk, e))


def decode(a, apk, out, frames, extra=()):
    shutil.rmtree(out, ignore_errors=True)
    apktool(a, "d", "-f", "-p", frames, *extra, "-o", out, apk)


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def write(p, t):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(t)


def list_smali(d):
    out = {}
    for root in sorted(glob.glob(os.path.join(d, "smali*"))):
        for dp, _, fs in os.walk(root):
            for f in fs:
                if f.endswith(".smali"):
                    p = os.path.join(dp, f)
                    out["L" + os.path.relpath(p, root).replace(os.sep, "/")[:-6] + ";"] = p
    return out


def next_smali_dir(d):
    idx = [int(m.group(1)) for x in glob.glob(d + "/smali*") for m in [re.search(r"smali_classes(\d+)$", x)] if m]
    return os.path.join(d, "smali_classes%d" % (max(idx + [1]) + 1))


def public_ids(d):
    p = os.path.join(d, "res/values/public.xml")
    return {e.get("id"): (e.get("type"), e.get("name")) for e in ET.parse(p).getroot() if e.get("id")}


def finalize(built_apk, original_apk, out_apk):
    """Keep ORIGINAL META-INF (signature identity), then zipalign if available."""
    tmp = out_apk + ".tmp"
    with zipfile.ZipFile(built_apk) as zin, zipfile.ZipFile(original_apk) as zorig, \
            zipfile.ZipFile(tmp, "w") as zout:
        names = set()
        for i in zin.infolist():
            if i.filename.startswith("META-INF/"):
                continue
            zout.writestr(i, zin.read(i.filename)); names.add(i.filename)
        for i in zorig.infolist():
            if i.filename.startswith("META-INF/") and i.filename not in names:
                zout.writestr(i, zorig.read(i.filename))
    try:
        sh("zipalign", "-p", "-f", "4", tmp, out_apk)
        os.remove(tmp)
    except Exception:
        os.replace(tmp, out_apk)


def install(new_file, target):
    """Replace target, keep SELinux label, drop stale odex/vdex."""
    label = None
    try:
        label = os.getxattr(target, "security.selinux")
    except Exception:
        pass
    shutil.copyfile(new_file, target)
    os.chmod(target, 0o644)
    if label:
        try:
            os.setxattr(target, "security.selinux", label)
        except Exception:
            pass
    shutil.rmtree(os.path.join(os.path.dirname(target), "oat"), ignore_errors=True)


def find_app(tree, names):
    for n in names:
        for dp, dn, fs in os.walk(tree):
            if n in fs and ("/priv-app/" in dp + "/" or "/app/" in dp + "/"):
                return os.path.join(dp, n)
    return None


def find_jars(tree):
    out = {}
    for dp, _, fs in os.walk(tree):
        if dp.endswith("/framework") or "/framework/" in dp + "/":
            for f in fs:
                if f.endswith(".jar"):
                    out.setdefault(f, os.path.join(dp, f))
    return out


# ------------------------------------------------------------------ smali member diffing
M_RE = re.compile(r"^\.method\b[^\n]*\n.*?^\.end method[ \t]*\n?", re.M | re.S)
F_RE = re.compile(r"^\.field\b[^\n]*\n(?:(?:[ \t]+\.annotation\b.*?^[ \t]+\.end annotation[ \t]*\n)+^\.end field[ \t]*\n)?",
                  re.M | re.S)
I_RE = re.compile(r"^\.implements\s+(\S+)[ \t]*\n", re.M)


def m_key(block):
    return block.split("\n", 1)[0].split()[-1]


def f_key(block):
    return block.split("\n", 1)[0].split(" = ")[0].split()[-1]


def plan_blocks(cr_text, ix_text, only=None):
    """Members IX has that crDroid lacks -> [(kind, key, text)]. `only` limits to given member keys."""
    have_m = {m_key(m.group(0)) for m in M_RE.finditer(cr_text)}
    have_f = {f_key(m.group(0)) for m in F_RE.finditer(cr_text)}
    have_i = {m.group(1) for m in I_RE.finditer(cr_text)}
    plan = []
    for m in I_RE.finditer(ix_text):
        if only is None and m.group(1) not in have_i:
            plan.append(("i", m.group(1), m.group(0)))
    for m in F_RE.finditer(ix_text):
        k = f_key(m.group(0))
        if k not in have_f and (only is None or k in only):
            plan.append(("f", k, m.group(0)))
    for m in M_RE.finditer(ix_text):
        k = m_key(m.group(0))
        if k not in have_m and (only is None or k in only):
            t = m.group(0)
            plan.append(("m", k, t if t.endswith("\n") else t + "\n"))
    return plan


def apply_plan(cr_text, plan):
    impl = "".join(p[2] for p in plan if p[0] == "i")
    fld = "".join(p[2] for p in plan if p[0] == "f")
    mth = "".join(p[2] for p in plan if p[0] == "m")
    if impl:
        m = re.search(r"^\.super[^\n]*\n", cr_text, re.M)
        if m:
            cr_text = cr_text[:m.end()] + impl + cr_text[m.end():]
    if fld:
        m = re.search(r"^\.method\b", cr_text, re.M)
        blk = MB + fld + ME
        cr_text = (cr_text[:m.start()] + blk + cr_text[m.start():]) if m else cr_text.rstrip("\n") + "\n" + blk
    if mth:
        cr_text = cr_text.rstrip("\n") + "\n\n" + MB + mth + ME
    return cr_text


def refs_of(text):
    return {m.group(1) + "->" + m.group(2) + m.group(3) for m in REF.finditer(text)}


# ------------------------------------------------------------------ framework augmentation
def augment_framework(a, fw, refs):
    miss = fw.missing(refs)
    if not miss:
        log("Framework: nothing missing, no framework changes")
        return
    log("Framework: %d IX framework references missing in crDroid -> adding them" % len(miss))
    cr_jars, ix_jars = find_jars(a.cr_tree), {os.path.basename(p): p for p in glob.glob(a.ix_fw + "/*.jar")}
    cache = {}

    def dec(kind, name):
        key = (kind, name)
        if key not in cache:
            src = (cr_jars if kind == "cr" else ix_jars).get(name)
            out = os.path.join(a.work, "fw_%s_%s" % (kind, name))
            try:
                if not src:
                    raise RuntimeError("jar not found")
                shutil.rmtree(out, ignore_errors=True)
                apktool(a, "d", "-f", "-r", "-o", out, src)
                cache[key] = (out, list_smali(out), [next_smali_dir(out)])
            except Exception as e:
                log("  framework decode failed for %s/%s: %s" % (kind, name, e))
                cache[key] = None
        return cache[key]

    pending = defaultdict(set)
    for r in miss:
        c, m = r.split("->", 1); pending[c].add(m)
    added_cls = added_mem = 0
    touched = set()
    for rnd in range(5):
        if not pending:
            break
        nxt = defaultdict(set)
        for cls, mems in pending.items():
            ijar = fw.ix_jar.get(cls)
            ix = dec("ix", ijar) if ijar else None
            if not ix or cls not in ix[1]:
                continue
            ix_text = read(ix[1][cls])
            exists = cls in fw.cr_jar
            tjar = fw.cr_jar.get(cls) or (ijar if ijar in cr_jars else "framework.jar")
            cr = dec("cr", tjar)
            if not cr:
                continue
            if not exists:
                dst = os.path.join(cr[2][0], cls[1:-1] + ".smali")
                write(dst, ix_text)
                cr[1][cls] = dst
                fw.crc.add(cls); fw.crm |= fw.ix_members_of(cls); fw.cr_jar[cls] = tjar
                new_text = ix_text; added_cls += 1
            else:
                if cls not in cr[1]:
                    continue
                cur = read(cr[1][cls])
                plan = plan_blocks(cur, ix_text, only=mems)
                if not plan:
                    continue
                write(cr[1][cls], apply_plan(cur, plan))
                for _, k, _t in plan:
                    fw.crm.add(cls + "->" + k)
                new_text = "".join(p[2] for p in plan); added_mem += len(plan)
            touched.add(tjar)
            for r in fw.missing(refs_of(new_text)):
                c, m = r.split("->", 1); nxt[c].add(m)
        pending = nxt
    log("Framework: +%d classes, +%d members" % (added_cls, added_mem))
    for name in touched:
        d = cache.get(("cr", name))
        if not d:
            continue
        out = os.path.join(a.work, "fw_built_" + name)
        try:
            apktool(a, "b", "-o", out, d[0])
            orig = cr_jars[name]
            oc, _, _ = dex_of_zip(orig); nc, _, _ = dex_of_zip(out)
            if not oc <= nc:
                raise RuntimeError("rebuilt jar lost %d classes" % len(oc - nc))
            final = out + ".final"
            with zipfile.ZipFile(orig) as zo, zipfile.ZipFile(out) as zn, zipfile.ZipFile(final, "w", zipfile.ZIP_DEFLATED) as zf:
                for i in zo.infolist():
                    if not re.fullmatch(r"classes\d*\.dex", i.filename):
                        zf.writestr(i, zo.read(i.filename))
                for n in zn.namelist():
                    if re.fullmatch(r"classes\d*\.dex", n):
                        zf.writestr(n, zn.read(n))
            install(final, orig)
            log("Framework: updated %s" % name)
        except Exception as e:
            log("Framework: rebuild of %s FAILED (%s) -> original kept" % (name, e))
    # stale boot images / odex must go or ART rejects the changed framework
    for dp, dn, fs in os.walk(a.cr_tree):
        if "/framework" in dp:
            for f in fs:
                if re.match(r"(boot.*\.(art|oat|vdex)|.*\.(odex|vdex))$", f):
                    try:
                        os.remove(os.path.join(dp, f))
                    except OSError:
                        pass


# ------------------------------------------------------------------ xml merging helpers
def key_of(e):
    return (e.tag, e.get("type"), e.get("name"))


def merge_values(ixf, crf):
    ir, cr = ET.parse(ixf), ET.parse(crf)
    root = cr.getroot()
    have = {key_of(e): e for e in root}
    n = 0
    for e in ir.getroot():
        if not e.get("name"):
            continue
        k = key_of(e)
        if k not in have:
            root.append(e); n += 1
        elif e.tag == "declare-styleable":  # add missing attrs inside an existing styleable
            names = {c.get("name") for c in have[k]}
            for c in e:
                if c.get("name") not in names:
                    have[k].append(c); n += 1
    if n:
        cr.write(crf, encoding="utf-8", xml_declaration=True)
    return n


def merge_prefs_into_category(ixf, crf):
    """Put IX-only preferences (by android:key) into an 'Infinity X' category of crDroid's screen."""
    t_ix, t_cr = ET.parse(ixf), ET.parse(crf)
    rc = t_cr.getroot()
    if not rc.tag.endswith("PreferenceScreen"):
        return 0
    keys = {e.get(A + "key") for e in rc.iter() if e.get(A + "key")}
    add = []

    def walk(e):
        for ch in list(e):
            k = ch.get(A + "key")
            if k and k not in keys:
                add.append(ch)
            else:
                walk(ch)
    walk(t_ix.getroot())
    if not add:
        return 0
    cat = ET.SubElement(rc, "PreferenceCategory")
    cat.set(A + "key", "ix_graft_category"); cat.set(A + "title", "Infinity X")
    for e in add:
        cat.append(e)
    t_cr.write(crf, encoding="utf-8", xml_declaration=True)
    return len(add)


def prune_prefs(path, bad_classes):
    tree = ET.parse(path); root = tree.getroot(); removed = 0
    for parent in list(root.iter()):
        for ch in list(parent):
            frag = ch.get(A + "fragment")
            if frag and cls_of(frag) in bad_classes:
                parent.remove(ch); removed += 1
    if removed:
        tree.write(path, encoding="utf-8", xml_declaration=True)
    return removed


def cls_of(name):
    return "L" + name.replace(".", "/") + ";"


def full_name(n, pkg):
    return (pkg + n) if n.startswith(".") else (n if "." in n else "%s.%s" % (pkg, n))


# ------------------------------------------------------------------ per-app merge
class AppMerge:
    def __init__(self, a, label, cr_apk, ix_apk):
        self.a, self.label, self.cr_apk, self.ix_apk = a, label, cr_apk, ix_apk
        self.work = os.path.join(a.work, label)
        self.cr, self.ix = self.work + "/cr", self.work + "/ix"
        self.dead = False
        self.refs = set()
        self.collided = set()

    def analyze(self):
        a = self.a
        os.makedirs(self.work, exist_ok=True)
        decode(a, self.cr_apk, self.cr, a.frames_cr); decode(a, self.ix_apk, self.ix, a.frames_ix)
        self.crs, self.ixs = list_smali(self.cr), list_smali(self.ix)
        if not self.crs or not self.ixs:
            raise RuntimeError("no smali (dex stripped into vdex); cannot merge")
        notR = lambda p: not re.search(r"/R(\$[^/]*)?\.smali$", p)
        self.new = {c: p for c, p in self.ixs.items() if c not in self.crs and notR(p)}
        self.new_text = {c: read(p) for c, p in self.new.items()}
        self.plans = {}
        for c, p in self.ixs.items():
            if c in self.crs and notR(p):
                plan = plan_blocks(read(self.crs[c]), read(p))
                if plan:
                    self.plans[c] = plan
        self.cls_refs = {c: refs_of(t) for c, t in self.new_text.items()}
        for r in self.cls_refs.values():
            self.refs |= r
        for pl in self.plans.values():
            self.refs |= refs_of("".join(x[2] for x in pl))
        nm = sum(len(v) for v in self.plans.values())
        log("%s: %d IX-only classes, %d shared classes get %d missing members (originals kept)"
            % (self.label, len(self.new), len(self.plans), nm))

    def unsafe(self, fw):
        return {c for c, r in self.cls_refs.items() if fw.missing(r)}

    # ---- resources
    def graft_res(self):
        cr, ix = self.cr, self.ix

        def idx(root):
            d = defaultdict(dict)
            for dp, _, fs in os.walk(root + "/res"):
                cfg = os.path.basename(dp)
                typ = cfg.split("-")[0]
                if typ == "values":
                    continue
                for f in fs:
                    d[(typ, f.split(".")[0])][cfg] = os.path.join(dp, f)
            return d
        cri, ixi = idx(cr), idx(ix)
        added = renamed = 0
        for (typ, name), cfgs in ixi.items():
            existing = cri.get((typ, name))
            if not existing:
                for cfg, p in cfgs.items():
                    dst = os.path.join(cr, "res", cfg, os.path.basename(p))
                    os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(p, dst); added += 1
                continue
            same = lambda x, y: open(x, "rb").read() == open(y, "rb").read()
            diff = any(cfg not in existing or not same(p, existing[cfg]) for cfg, p in cfgs.items())
            renamable = typ in RENAME_TYPES and all(p.endswith(".xml") for p in cfgs.values())
            if diff and renamable:
                for cfg, p in cfgs.items():
                    dst = os.path.join(cr, "res", cfg, "ix_" + os.path.basename(p))
                    os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(p, dst)
                    if typ == "xml" and cfg in existing:
                        try:
                            merge_prefs_into_category(p, existing[cfg])
                        except Exception:
                            pass
                self.collided.add((typ, name)); renamed += 1
            elif not renamable:
                for cfg, p in cfgs.items():
                    if cfg not in existing:
                        dst = os.path.join(cr, "res", cfg, os.path.basename(p))
                        os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(p, dst); added += 1
        vals = 0
        for dp, _, fs in os.walk(ix + "/res"):
            if not os.path.basename(dp).startswith("values"):
                continue
            for f in fs:
                if f == "public.xml":
                    continue
                src = os.path.join(dp, f); dst = os.path.join(cr, os.path.relpath(src, ix))
                if not os.path.exists(dst):
                    os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copyfile(src, dst); vals += 1
                else:
                    try:
                        vals += merge_values(src, dst)
                    except Exception as e:
                        log("    values merge skipped for %s: %s" % (f, e))
        log("%s: resources +%d files, %d separate ix_ copies, +%d value entries" % (self.label, added, renamed, vals))

    # ---- manifest
    def graft_manifest(self, unsafe, guard):
        mi, mc = ET.parse(self.ix + "/AndroidManifest.xml"), ET.parse(self.cr + "/AndroidManifest.xml")
        pkg = mc.getroot().get("package", "")
        ia, ca = mi.getroot().find("application"), mc.getroot().find("application")
        have = {full_name(e.get(A + "name"), pkg) for e in ca if e.get(A + "name")}
        added = 0
        for e in list(ia):
            n = e.get(A + "name")
            if e.tag not in ("activity", "service", "receiver", "provider", "activity-alias") or not n:
                continue
            fn = full_name(n, pkg)
            c = cls_of(fn)
            if fn in have or (c not in self.new and c not in self.crs):
                continue
            if guard and c in unsafe:
                continue
            ca.append(e); added += 1
        for tag in ("uses-permission", "permission", "uses-feature"):
            existing = {e.get(A + "name") for e in mc.getroot().findall(tag)}
            for e in mi.getroot().findall(tag):
                if e.get(A + "name") not in existing:
                    mc.getroot().insert(0, e)
        mc.write(self.cr + "/AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
        log("%s: %d manifest components added" % (self.label, added))

    # ---- apply
    def apply(self, unsafe, guard):
        a, cr = self.a, self.cr
        sdir = next_smali_dir(cr)
        good = [c for c in self.new]
        for c in good:
            write(os.path.join(sdir, c[1:-1] + ".smali"), self.new_text[c])
        for c, plan in self.plans.items():
            p = self.crs[c]
            write(p, apply_plan(read(p), plan))
        self.graft_res()
        if guard:
            n = 0
            for x in glob.glob(cr + "/res/xml*/*.xml"):
                try:
                    n += prune_prefs(x, unsafe)
                except Exception:
                    pass
            if n:
                log("%s: %d preference entries hidden (class still references missing framework APIs)" % (self.label, n))
        self.graft_manifest(unsafe, guard)

        p1 = self.work + "/pass1.apk"
        apktool(a, "b", "-p", a.frames_cr, "-o", p1, cr)
        tmp = self.work + "/p1dec"
        decode(a, p1, tmp, a.frames_cr, ("-s",))
        ix_ids = public_ids(self.ix)
        cr_by_name = {v: k for k, v in public_ids(tmp).items()}
        n = [0]

        def mapper(m):
            nm = ix_ids.get(m.group(0))
            if not nm:
                return m.group(0)
            nid = None
            if nm in self.collided:
                nid = cr_by_name.get((nm[0], "ix_" + nm[1]))
            nid = nid or cr_by_name.get(nm)
            if nid and nid != m.group(0):
                n[0] += 1; return nid
            return m.group(0)
        for c in good:
            p = os.path.join(sdir, c[1:-1] + ".smali")
            write(p, HEX.sub(mapper, read(p)))
        for c in self.plans:
            p = self.crs[c]
            t = re.sub(r"(# ix-graft-begin\n)(.*?)(# ix-graft-end\n)",
                       lambda m: m.group(1) + HEX.sub(mapper, m.group(2)) + m.group(3), read(p), flags=re.S)
            write(p, t)
        log("%s: %d resource IDs remapped" % (self.label, n[0]))
        p2 = self.work + "/pass2.apk"
        apktool(a, "b", "-p", a.frames_cr, "-o", p2, cr)
        out = self.work + "/%s.merged.apk" % self.label
        finalize(p2, self.cr_apk, out)
        install(out, self.cr_apk)
        log("%s: merged APK installed -> %s" % (self.label, self.cr_apk))


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apktool", required=True)
    ap.add_argument("--cr-tree", required=True, help="writable crDroid tree (system/system_ext/product)")
    ap.add_argument("--ix-tree", required=True, help="Infinity X tree")
    ap.add_argument("--cr-fw", required=True); ap.add_argument("--ix-fw", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--settings", choices=["keep", "graft"], default="graft")
    ap.add_argument("--systemui", default="merge-missing",
                    help="keep|keep-crdroid | merge-missing | swap-if-compatible")
    ap.add_argument("--framework", choices=["off", "add"], default="add")
    ap.add_argument("--guard", choices=["on", "off"], default="on")
    # legacy flags (ignored)
    ap.add_argument("--cr-sysext"); ap.add_argument("--ix-sysext")
    a = ap.parse_args()
    ui_mode = {"keep-crdroid": "keep", "graft": "merge-missing", "merge": "merge-missing"}.get(a.systemui, a.systemui)
    a.frames_cr, a.frames_ix = a.work + "/frames_cr", a.work + "/frames_ix"
    os.makedirs(a.work, exist_ok=True)
    try:
        install_frames(a, a.cr_fw, a.frames_cr); install_frames(a, a.ix_fw, a.frames_ix)
        fw = Framework(a.ix_fw, a.cr_fw)
    except Exception as e:
        log("framework setup failed (%s): keeping stock crDroid apps" % e)
        write_report(a); return

    st_names, ui_names = ["Settings.apk", "SettingsGoogle.apk"], ["SystemUI.apk", "SystemUIGoogle.apk"]
    apps = []
    for label, mode_on, names in (("settings", a.settings == "graft", st_names),
                                  ("systemui", ui_mode == "merge-missing", ui_names)):
        if not mode_on:
            continue
        c, i = find_app(a.cr_tree, names), find_app(a.ix_tree, names)
        if c and i:
            apps.append(AppMerge(a, label, c, i))
        else:
            log("%s: apk not found (cr=%s ix=%s) -> kept stock" % (label, c, i))

    for m in apps:
        try:
            m.analyze()
        except Exception as e:
            m.dead = True; log("%s: analysis FAILED (%s) -> stock kept" % (m.label, e))
    live = [m for m in apps if not m.dead]

    if a.framework == "add" and live:
        try:
            augment_framework(a, fw, set().union(*(m.refs for m in live)))
        except Exception as e:
            log("Framework: augmentation FAILED (%s) -> framework left as is" % e)

    for m in live:
        try:
            m.apply(m.unsafe(fw), a.guard == "on")
        except Exception as e:
            log("%s: merge FAILED (%s) -> stock crDroid kept" % (m.label, e))

    if ui_mode == "swap-if-compatible":
        c, i = find_app(a.cr_tree, ui_names), find_app(a.ix_tree, ui_names)
        if c and i:
            try:
                _, _, refs = dex_of_zip(i)
                bad = fw.missing(refs)
                if bad:
                    log("SystemUI: NOT swapped, %d IX framework refs missing, e.g. %s" % (len(bad), sorted(bad)[:5]))
                else:
                    out = a.work + "/SystemUI.swapped.apk"
                    finalize(i, c, out); install(out, c); log("SystemUI: swapped to Infinity X")
            except Exception as e:
                log("SystemUI: swap FAILED (%s) -> stock kept" % e)
    write_report(a)


def write_report(a):
    with open(os.path.join(a.work, "merge-report.txt"), "w") as f:
        f.write("\n".join(REPORT) + "\n")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        print("graft_apk crashed: %s -> stock apps kept" % e)
