#!/usr/bin/env python3
"""Renders the Jinja expressions of playbooks/desktop.yml that build the theme file lists, with stub values.

The playbook's stale-file removal keeps what its SHA256SUMS-derived list says and removes everything else under the
theme trees, so the two `set_fact` expressions have to read a SHA256SUMS the way the copy does: an empty or foreign
file, CRLF line endings, a `*` binary marker, a `./` prefix or an overridden location with a trailing slash must not
produce paths the device never has. This renders the expressions themselves (read from the playbook, not copied here)
with ansible's own Templar, so no playbook runs against a host: `run.sh` finds a python that has ansible and calls
this file with the repository root. The removal's own expression is rendered too, against a stub list of device files,
to show that it keeps what the copy installs and fontconfig's own `.uuid` and `*.cache-*` files; so are the two
expressions of the theme checks (the font a removal dropped, and the XFCE session's XDG_CONFIG_DIRS), which decide
whether fontconfig is refreshed and whether the session really reads the theme's defaults.
"""

import os
import shutil
import sys
import tempfile

import ansible.plugins.loader as plugin_loader  # noqa: E402 - the lookup plugin needs the loader initialised first
import yaml
from ansible.parsing.dataloader import DataLoader
from ansible.template import Templar, trust_as_template

plugin_loader.init_plugin_loader()

THEME_DIR = "/usr/share/themes/Teknoir"
XDG_DIR = "/usr/local/share/teknoir-desktop/xdg"
FONTS_DIR = "/usr/local/share/fonts/teknoir"
H = "0" * 64
PLAYBOOK = "playbooks/desktop.yml"
FILES_TASK = "The files the vendored bundle installs"
EXPECTED_TASK = "The theme files the bundle installs, where they go on the device"
STALE_TASK = "Remove theme files that the vendored bundle does not have any more"
FONTS_TASK = "Make the theme fonts known to fontconfig"
XDG_TASK = "The XFCE session runs with the Teknoir defaults"

fail = 0


def ok(name, cond, detail=""):
    global fail
    if cond:
        print(f"PASS: {name}")
    else:
        fail = 1
        print(f"FAIL: {name}" + (f": {detail}" if detail else ""))


def tasks(tasks_list):
    for task in tasks_list or []:
        yield task
        yield from tasks(task.get("block"))


def task_expression(playbook, name, module="ansible.builtin.set_fact", field=None):
    for play in playbook:
        for task in tasks(play.get("tasks")):
            if task.get("name") == name:
                if field is not None:
                    return task[field]
                for key, value in task.items():
                    if key.startswith(module):
                        ((_, expression),) = value.items()
                        return expression
    raise SystemExit(f"{PLAYBOOK}: no task {name!r}")


def render(expression, variables):
    templar = Templar(loader=DataLoader(), variables=variables)
    return templar.template(trust_as_template(expression))


def as_bool(value):
    # A whole-expression template renders to a bool with jinja2 native types and to "True"/"False" otherwise.
    return value is True or value == "True"


def bundle_list(files_expr, sums):
    directory = tempfile.mkdtemp()
    try:
        bundle = os.path.join(directory, "files", "teknoir-desktop")
        os.makedirs(bundle)
        with open(os.path.join(bundle, "SHA256SUMS"), "w", newline="") as handle:
            handle.write(sums)
        variables = {
            "playbook_dir": directory,
            "desktop_files": "files/teknoir-desktop",
            "ansible_search_path": [directory],
        }
        return render(files_expr, variables)
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def expected_list(expected_expr, files, **overrides):
    variables = {
        "desktop_bundle_files": files,
        "desktop_theme_dir": THEME_DIR,
        "desktop_theme_xdg_dir": XDG_DIR,
        "desktop_theme_fonts_dir": FONTS_DIR,
    }
    variables.update(overrides)
    return render(expected_expr, variables)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    with open(os.path.join(root, PLAYBOOK), encoding="utf-8") as handle:
        playbook = yaml.safe_load(handle)
    files_expr = task_expression(playbook, FILES_TASK)
    expected_expr = task_expression(playbook, EXPECTED_TASK)
    ok("the playbook has the two theme list expressions", bool(files_expr and expected_expr))

    normal = (
        f"{H}  SOURCE\n"
        f"{H}  teknoir-desktop-session\n"
        f"{H}  teknoir-desktop.service\n"
        f"{H}  theme/desktop-theme-migrate\n"
        f"{H}  theme/teknoir-mark.svg\n"
        f"{H}  theme/fonts/HankenGrotesk-VF.ttf\n"
        f"{H}  theme/themes/Teknoir/gtk-3.0/gtk.css\n"
        f"{H}  theme/themes/Teknoir/index.theme\n"
        f"{H}  theme/xdg/xfce4/panel/default.xml\n"
    )
    normal_expected = [
        f"{THEME_DIR}/gtk-3.0/gtk.css",
        f"{THEME_DIR}/index.theme",
        f"{XDG_DIR}/xfce4/panel/default.xml",
        f"{FONTS_DIR}/HankenGrotesk-VF.ttf",
    ]

    files = bundle_list(files_expr, normal)
    ok(
        "a normal SHA256SUMS lists every path it names",
        sorted(files) == sorted(
            [
                "SOURCE",
                "teknoir-desktop-session",
                "teknoir-desktop.service",
                "theme/desktop-theme-migrate",
                "theme/teknoir-mark.svg",
                "theme/fonts/HankenGrotesk-VF.ttf",
                "theme/themes/Teknoir/gtk-3.0/gtk.css",
                "theme/themes/Teknoir/index.theme",
                "theme/xdg/xfce4/panel/default.xml",
            ]
        ),
        f"{files}",
    )
    expected = expected_list(expected_expr, files)
    ok("the theme, xdg and font files are expected where they are installed", sorted(expected) == sorted(normal_expected), f"{expected}")
    ok(
        "nothing outside the three theme trees is expected",
        all(p.startswith((THEME_DIR + "/", XDG_DIR + "/", FONTS_DIR + "/")) for p in expected),
        f"{expected}",
    )

    ok("an empty SHA256SUMS expects no device file", expected_list(expected_expr, bundle_list(files_expr, "")) == [])

    crlf = normal.replace("\n", "\r\n")
    ok("a CRLF SHA256SUMS gives the same paths without the CR", sorted(bundle_list(files_expr, crlf)) == sorted(files),
       f"{bundle_list(files_expr, crlf)!r}")

    binary = f"{H} *theme/xdg/xfce4/panel/default.xml\n{H} *theme/themes/Teknoir/index.theme\n"
    ok("a * binary marker is stripped", sorted(bundle_list(files_expr, binary)) == ["theme/themes/Teknoir/index.theme", "theme/xdg/xfce4/panel/default.xml"],
       f"{bundle_list(files_expr, binary)!r}")

    dotted = f"{H}  ./theme/xdg/xfce4/panel/default.xml\n{H}  ./theme/fonts/HankenGrotesk-VF.ttf\n"
    ok("a ./ prefix is stripped", sorted(bundle_list(files_expr, dotted)) == ["theme/fonts/HankenGrotesk-VF.ttf", "theme/xdg/xfce4/panel/default.xml"],
       f"{bundle_list(files_expr, dotted)!r}")

    trailing = expected_list(expected_expr, files, desktop_theme_xdg_dir=XDG_DIR + "/", desktop_theme_fonts_dir=FONTS_DIR + "//")
    ok("a location with a trailing slash keeps one slash", sorted(trailing) == sorted(normal_expected), f"{trailing}")

    # The font test before fc-cache: a font the removal dropped leaves fontconfig's cache stale, a theme file that is
    # not a font does not, and an unchanged result is not a removal.
    fonts_expr = task_expression(playbook, FONTS_TASK, field="vars")["desktop_theme_fonts_dropped"]

    def fonts_dropped(results):
        return as_bool(render(fonts_expr, {"desktop_theme_fonts_dir": FONTS_DIR,
                                           "desktop_theme_stale": {"results": results}}))

    def stale(item, changed=True):
        return {"item": item, "changed": changed}

    ok("a dropped font asks fontconfig for a new cache", fonts_dropped([stale(f"{FONTS_DIR}/Dropped-VF.ttf")]))
    ok("a dropped theme file that is not a font does not",
       not fonts_dropped([stale(f"{THEME_DIR}/gtk-3.0/gtk.css~")]))
    ok("a stale result that did not change does not",
       not fonts_dropped([stale(f"{FONTS_DIR}/Dropped-VF.ttf", changed=False)]))
    ok("no stale result at all does not", not fonts_dropped([]))

    # The XFCE session check: XDG_CONFIG_DIRS has to start with the theme's xdg directory, and the directory is put
    # into the pattern through regex_escape, so a dot in it cannot stand for another character.
    # A `that:` is a bare expression (no {{ }}): assert evaluates it like a when:, so it is templated the same way here.
    xdg_expr = task_expression(playbook, XDG_TASK, field="ansible.builtin.assert")["that"]

    def xdg_with(xdg_dir, *lines):
        return as_bool(render("{{ " + xdg_expr + " }}", {
            "desktop_theme_xdg_dir": xdg_dir,
            "desktop_theme_env": {"stdout_lines": list(lines)},
        }))

    ok("the session's XDG_CONFIG_DIRS with the theme first passes",
       xdg_with(XDG_DIR, "session=xfce pid=42", f"XDG_CONFIG_DIRS={XDG_DIR}:/etc/xdg"))
    ok("a longer directory name does not pass for the theme's",
       not xdg_with(XDG_DIR, f"XDG_CONFIG_DIRS={XDG_DIR}2:/etc/xdg"))
    ok("a session without XDG_CONFIG_DIRS does not pass", not xdg_with(XDG_DIR, "session=xfce pid=42"))
    dotted = "/usr/local/share/teknoir.d/xdg"
    ok("the pattern escapes a dot in the location",
       xdg_with(dotted, f"XDG_CONFIG_DIRS={dotted}:/etc/xdg")
       and not xdg_with(dotted, "XDG_CONFIG_DIRS=/usr/local/share/teknoirXd/xdg:/etc/xdg"))

    # The removal keeps what the copy installs and removes the rest, except fontconfig's own files in the font
    # directory (fc-cache 2.13 on Ubuntu 20.04 writes a .uuid into each font directory, and its caches are *.cache-*).
    stale_expr = task_expression(playbook, STALE_TASK, field="loop")
    found = [
        f"{THEME_DIR}/gtk-3.0/gtk.css",
        f"{THEME_DIR}/gtk-3.0/gtk.css~",
        f"{XDG_DIR}/xfce4/panel/old.xml",
        f"{FONTS_DIR}/HankenGrotesk-VF.ttf",
        f"{FONTS_DIR}/Dropped-VF.ttf",
        f"{FONTS_DIR}/.uuid",
        f"{FONTS_DIR}/Dropped-VF.ttf.cache-8",
        f"{FONTS_DIR}/dropped.dir/.uuid",
    ]
    stale = render(stale_expr, {"desktop_theme_found": {"files": [{"path": p} for p in found]}, "desktop_theme_expected": expected})
    ok(
        "the removal keeps what the bundle installs and fontconfig's own files, and removes the rest",
        sorted(stale)
        == sorted([f"{THEME_DIR}/gtk-3.0/gtk.css~", f"{XDG_DIR}/xfce4/panel/old.xml", f"{FONTS_DIR}/Dropped-VF.ttf"]),
        f"{stale}",
    )

    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
