#!/usr/bin/env python3
"""
graft_apk.py - best-effort merge of Infinity X app features into crDroid's Settings/SystemUI.

Safety rule: this script NEVER aborts the build. Any failure keeps the stock crDroid APK
for that app and says so in the report.

Settings  : "graft" = copy Infinity X-only classes/resources/manifest entries/preferences into
            crDroid's Settings. Anything that references framework APIs missing from crDroid's
            framework is pruned automatically (this is the "disable whatever breaks" part).
SystemUI  : the two cannot be merged class-by-class (Dagger-generated wiring), so the options are
            keep (crDroid) or swap-if-compatible (Infinity X's APK, only when all of its framework
            references exist in crDroid's framework).
"""
import argparse, glob, os, re, shutil, struct, subprocess, sys, zipfile
import xml.etree.ElementTree as ET

NS = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", NS)
A = "{%s}" % NS
REF = re.compile(r'(L[\w/$]+;)->([\w$<>]+)(\([^)\s]*\)[\w/$;\[]+|:[\w/$;\[]+)')
CLS = re.compile(r'L[\w/$]+;')
HEX = re.compile(r'0x7f[0-9a-f]{6}')
REPORT = []


def log(msg):
    print(msg, flush=True)
    REPORT.append(msg)


def sh(*cmd, **kw):
    return subprocess.run(list(cmd), check=True, **kw)


# ---------------------------------------------------------------- dex parsing
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
    """Class/member sets of both ROMs' framework jars, used to find references that would crash."""
    def __init__(self, ix_dir, cr_dir):
        self.ixc, self.ixm = self._load(ix_dir)
        self.crc, self.crm = self._load(cr_dir)
        log("framework classes: infinityx=%d crdroid=%d" % (len(self.ixc), len(self.crc)))

    @staticmethod
    def _load(d):
        c, m = set(), set()
        for j in glob.glob(os.path.join(d, "*.jar")):
            a, b, _ = dex_of_zip(j); c |= a; m |= b
        return c, m

    def missing(self, refs):
        bad = set()
        for r in refs:
            cls = r.split("->")[0]
            if cls in self.ixc and (cls not in self.crc or (r in self.ixm and r not in self.crm)):
                bad.add(r)
        return bad


# ---------------------------------------------------------------- apktool helpers
def apktool(a, *args):
    sh("java", "-jar", a.apktool, *args, stdout=subprocess.DEVNULL)


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


def list_smali(d):
    out = {}
    for root in sorted(glob.glob(os.path.join(d, "smali*"))):
        for dp, _, fs in os.walk(root):
            for f in fs:
                if f.endswith(".smali"):
                    p = os.path.join(dp, f)
                    out["L" + os.path.relpath(p, root)[:-6] + ";"] = p
    return out


def public_ids(d):
    p = os.path.join(d, "res/values/public.xml")
    return {e.get("id"): (e.get("type"), e.get("name")) for e in ET.parse(p).getroot() if e.get("id")}


def finalize(built_apk, original_apk, out_apk):
    """Keep the ORIGINAL (crDroid) META-INF so the platform-signature identity is preserved,
    then zipalign. The digests no longer match, which Android tolerates for system-partition apps
    only; it cannot be re-signed with crDroid's private key."""
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


def install(new_apk, target):
    """Replace target APK, preserving its SELinux label, drop stale odex/vdex."""
    label = None
    try:
        label = os.getxattr(target, "security.selinux")
    except Exception:
        pass
    shutil.copyfile(new_apk, target)
    os.chmod(target, 0o644)
    if label:
        try:
            os.setxattr(target, "security.selinux", label)
        except Exception:
            pass
    shutil.rmtree(os.path.join(os.path.dirname(target), "oat"), ignore_errors=True)


def find_app(root, names):
    for sub in ("priv-app", "app"):
        for n in names:
            hit = glob.glob(os.path.join(root, sub, "*", n))
            if hit:
                return hit[0]
    return None


# ---------------------------------------------------------------- Settings graft
def cls_of(name):
    return "L" + name.replace(".", "/") + ";"


def merge_values(ixf, crf):
    ir, cr = ET.parse(ixf), ET.parse(crf)
    root = cr.getroot()
    key = lambda e: (e.tag, e.get("type"), e.get("name"))
    have = {key(e) for e in root}
    n = 0
    for e in ir.getroot():
        if e.get("name") and key(e) not in have:
            root.append(e); n += 1
    if n:
        cr.write(crf, encoding="utf-8", xml_declaration=True)
    return n


def prune_prefs(path, bad_classes):
    tree = ET.parse(path); root = tree.getroot(); removed = 0
    for parent in list(root.iter()):
        for ch in list(parent):
            frag = ch.get(A + "fragment")
            if frag and cls_of(frag) in bad_classes:
                parent.remove(ch); removed += 1
    tree.write(path, encoding="utf-8", xml_declaration=True)
    return removed


def graft_settings(a, fw, cr_apk, ix_apk, work):
    cr, ix = work + "/cr", work + "/ix"
    decode(a, cr_apk, cr, a.frames_cr); decode(a, ix_apk, ix, a.frames_ix)
    crs, ixs = list_smali(cr), list_smali(ix)
    if not crs or not ixs:
        raise RuntimeError("no smali (dex is stripped into a vdex); cannot graft")
    new = {c: p for c, p in ixs.items() if c not in crs and not re.search(r"/R(\$[^/]*)?\.smali$", p)}
    texts = {c: open(p, encoding="utf-8", errors="replace").read() for c, p in new.items()}
    bad = set()
    for c, t in texts.items():
        refs = {m.group(1) + "->" + m.group(2) + m.group(3) for m in REF.finditer(t)}
        if fw.missing(refs):
            bad.add(c)
    changed = True
    while changed:
        changed = False
        for c, t in texts.items():
            if c not in bad and any(k in bad for k in set(CLS.findall(t))):
                bad.add(c); changed = True
    good = [c for c in new if c not in bad]
    log("  Settings: %d Infinity X-only classes, %d disabled (missing framework APIs), %d grafted"
        % (len(new), len(bad), len(good)))
    for c in sorted(bad)[:60]:
        log("    disabled: " + c)

    # smali
    idx = [int(m.group(1) or 1) for d in glob.glob(cr + "/smali*") for m in [re.search(r"classes(\d+)$", d)] if m] or [1]
    sdir = os.path.join(cr, "smali_classes%d" % (max(idx) + 1))
    for c in good:
        dst = os.path.join(sdir, c[1:-1] + ".smali")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(new[c], dst)

    # resources
    for dp, _, fs in os.walk(ix + "/res"):
        for f in fs:
            if f == "public.xml":
                continue
            src = os.path.join(dp, f)
            dst = os.path.join(cr, os.path.relpath(src, ix))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.exists(dst):
                shutil.copyfile(src, dst)
            elif "/values" in dst and f.endswith(".xml"):
                try:
                    merge_values(src, dst)
                except Exception as e:
                    log("    values merge skipped for %s: %s" % (f, e))
            elif "/res/xml" in dst and f.endswith(".xml"):
                try:
                    t_ix, t_cr = ET.parse(src), ET.parse(dst)
                    keys = {e.get(A + "key") for e in t_cr.getroot().iter()}
                    n = 0
                    for e in list(t_ix.getroot()):
                        k = e.get(A + "key")
                        if k and k not in keys:
                            t_cr.getroot().append(e); n += 1
                    if n:
                        t_cr.write(dst, encoding="utf-8", xml_declaration=True)
                except Exception as e:
                    log("    prefs merge skipped for %s: %s" % (f, e))
    for x in glob.glob(cr + "/res/xml*/*.xml"):
        try:
            prune_prefs(x, bad)
        except Exception:
            pass

    # manifest
    mi, mc = ET.parse(ix + "/AndroidManifest.xml"), ET.parse(cr + "/AndroidManifest.xml")
    ia, ca = mi.getroot().find("application"), mc.getroot().find("application")
    have = {e.get(A + "name") for e in ca}
    added = 0
    for e in ia:
        n = e.get(A + "name")
        if e.tag in ("activity", "service", "receiver", "provider", "activity-alias") and n and n not in have \
                and cls_of(n) in new and cls_of(n) not in bad:
            ca.append(e); added += 1
    perms = {e.get(A + "name") for e in mc.getroot().findall("uses-permission")}
    for e in mi.getroot().findall("uses-permission"):
        if e.get(A + "name") not in perms:
            mc.getroot().insert(0, e)
    mc.write(cr + "/AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
    log("  Settings: %d manifest components added" % added)

    # pass 1 build to learn crDroid's resource IDs, remap grafted smali, pass 2 build
    p1 = work + "/pass1.apk"
    apktool(a, "b", "-p", a.frames_cr, "-o", p1, cr)
    tmp = work + "/p1dec"
    decode(a, p1, tmp, a.frames_cr, ("-s",))
    ix_ids = public_ids(ix)
    cr_by_name = {v: k for k, v in public_ids(tmp).items()}
    remapped = 0
    for dp, _, fs in os.walk(sdir):
        for f in fs:
            p = os.path.join(dp, f)
            t = open(p, encoding="utf-8").read()

            def sub(m):
                nonlocal remapped
                nm = ix_ids.get(m.group(0))
                nid = cr_by_name.get(nm) if nm else None
                if nid and nid != m.group(0):
                    remapped += 1; return nid
                return m.group(0)
            open(p, "w", encoding="utf-8").write(HEX.sub(sub, t))
    log("  Settings: %d resource IDs remapped" % remapped)
    p2 = work + "/pass2.apk"
    apktool(a, "b", "-p", a.frames_cr, "-o", p2, cr)
    out = work + "/Settings.merged.apk"
    finalize(p2, cr_apk, out)
    return out


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apktool", required=True)
    ap.add_argument("--cr-sysext", required=True, help="writable copy of crDroid system_ext")
    ap.add_argument("--ix-sysext", required=True, help="copy of Infinity X system_ext")
    ap.add_argument("--cr-fw", required=True); ap.add_argument("--ix-fw", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--settings", choices=["keep", "graft"], default="graft")
    ap.add_argument("--systemui", choices=["keep", "swap-if-compatible"], default="keep")
    a = ap.parse_args()
    a.frames_cr, a.frames_ix = a.work + "/frames_cr", a.work + "/frames_ix"
    os.makedirs(a.work, exist_ok=True)
    try:
        install_frames(a, a.cr_fw, a.frames_cr); install_frames(a, a.ix_fw, a.frames_ix)
        fw = Framework(a.ix_fw, a.cr_fw)
    except Exception as e:
        log("framework setup failed (%s): keeping stock crDroid apps" % e)
        write_report(a); return

    st_names = ["Settings.apk", "SettingsGoogle.apk"]
    ui_names = ["SystemUI.apk", "SystemUIGoogle.apk"]

    if a.settings == "graft":
        cr_app, ix_app = find_app(a.cr_sysext, st_names), find_app(a.ix_sysext, st_names)
        if cr_app and ix_app:
            try:
                out = graft_settings(a, fw, cr_app, ix_app, a.work + "/settings")
                install(out, cr_app); log("Settings: merged APK installed")
            except Exception as e:
                log("Settings: merge FAILED (%s) -> stock crDroid Settings kept" % e)
        else:
            log("Settings: apk not found (cr=%s ix=%s) -> kept stock" % (cr_app, ix_app))

    if a.systemui == "swap-if-compatible":
        cr_app, ix_app = find_app(a.cr_sysext, ui_names), find_app(a.ix_sysext, ui_names)
        if cr_app and ix_app:
            try:
                _, _, refs = dex_of_zip(ix_app)
                if not refs:
                    raise RuntimeError("no readable dex in Infinity X SystemUI")
                bad = fw.missing(refs)
                if bad:
                    log("SystemUI: NOT swapped, %d Infinity X framework refs missing in crDroid, e.g. %s"
                        % (len(bad), sorted(bad)[:5]))
                else:
                    out = a.work + "/SystemUI.swapped.apk"
                    finalize(ix_app, cr_app, out); install(out, cr_app)
                    log("SystemUI: swapped to Infinity X (all framework refs satisfied)")
            except Exception as e:
                log("SystemUI: swap FAILED (%s) -> stock crDroid SystemUI kept" % e)
        else:
            log("SystemUI: apk not found -> kept stock")
    write_report(a)


def write_report(a):
    with open(os.path.join(a.work, "merge-report.txt"), "w") as f:
        f.write("\n".join(REPORT) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never fail the workflow from here
        print("graft_apk crashed: %s -> stock apps kept" % e)
