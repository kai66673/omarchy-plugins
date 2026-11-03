#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

DEFAULT_WORKSPACE = os.path.expanduser("~/BAS/bcad-ws")
DEFAULT_BRANCH = "main"
GIT_TIMEOUT = 10
NETWORK_TIMEOUT = 180
TERMINAL_CANDIDATES = ("kitty", "foot", "alacritty", "xterm")
DEFAULT_DIFF_SIZE = (1400, 900)
DIFF_WINDOW_CLASS = "git-diff"


def git_env():
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_EDITOR"] = "true"
    env["GIT_SEQUENCE_EDITOR"] = "true"
    env.setdefault("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")
    return env


def run_git(path, args, timeout=GIT_TIMEOUT):
    try:
        proc = subprocess.run(
            ["git", "-C", path] + args,
            check=False, capture_output=True,
            text=True,
            timeout=timeout,
            env=git_env(),
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    except (FileNotFoundError, OSError) as exc:
        return 1, "", str(exc)


def read_repos(workspace):
    config_path = os.path.join(workspace, "packages.json")
    with open(config_path, encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, list):
        raise TypeError("packages.json must be an array")

    repos = []
    for item in data:
        if not isinstance(item, dict):
            continue
        dest = str(item.get("dest") or "").strip()
        if not dest:
            continue
        repos.append(
            {
                "url": str(item.get("url") or ""),
                "dest": dest,
                "branch": str(item.get("branch") or DEFAULT_BRANCH),
            }
        )
    return repos


def repo_path(workspace, dest):
    return os.path.join(workspace, "packages", dest)


def inspect_repo(path):
    row = {
        "branch": "",
        "currentRef": "",
        "dirty": 0,
        "state": "",
        "label": "",
        "detail": "",
    }

    if not os.path.isdir(path):
        row.update(state="missing", label="Missing", detail="package directory not found")
        return row

    code, out, err = run_git(path, ["rev-parse", "--is-inside-work-tree"])
    if code != 0 or out != "true":
        row.update(
            state="error",
            label="Not a git repository",
            detail=err or "not a git repository",
        )
        return row

    code, out, _ = run_git(path, ["symbolic-ref", "-q", "HEAD"])
    if code == 0 and out:
        row["currentRef"] = out
        prefix = "refs/heads/"
        row["branch"] = out.removeprefix(prefix)
    else:
        code, out, _ = run_git(path, ["rev-parse", "--short", "HEAD"])
        row["branch"] = out or "(detached)"
    return row


def working_tree_clean(path):
    code, out, _ = run_git(path, ["status", "--porcelain", "--untracked-files=normal"])
    if code != 0:
        return False, "git status failed"

    lines = [line for line in out.splitlines() if line.strip()]
    if not lines:
        return True, ""

    untracked = any(line.startswith("??") for line in lines)
    tracked = any(not line.startswith("??") for line in lines)
    if tracked and untracked:
        return False, "modified + untracked files"
    if untracked:
        return False, "untracked files"
    return False, "modified files"


def all_branches(path):
    # Получаем локальные и удаленные ветки одной командой
    code, out, _ = run_git(
        path,
        ["branch", "-a", "--format=%(refname:short)"],
    )
    if code != 0:
        return []
    branches = []
    for line in out.splitlines():
        name = line.strip()
        if not name or "->" in name:
            continue
        # Убираем префикс "origin/", чтобы в выпадающем списке имена были чистыми
        if name.startswith("origin/"):
            short_name = name[7:]
            if short_name not in branches:
                branches.append(short_name)
        else:
            if name not in branches:
                branches.append(name)
    return sorted(branches)


def action_status(workspace, repos):
    rows = []
    dirty = untracked_count = missing = errors = 0

    for repo in repos:
        path = repo_path(workspace, repo["dest"])
        row = inspect_repo(path)
        row["dest"] = repo["dest"]
        row["expectedBranch"] = repo["branch"]

        if row["state"] == "missing":
            missing += 1
        elif row["state"] == "error":
            errors += 1
        else:
            code, out, _ = run_git(
                path, ["status", "--porcelain", "--untracked-files=normal"]
            )
            if code != 0:
                row.update(state="error", label="Error", detail="git status failed")
                errors += 1
            else:
                lines = [line for line in out.splitlines() if line.strip()]
                untracked_lines = [line for line in lines if line.startswith("??")]
                untracked = len(untracked_lines)
                tracked = len(lines) - untracked
                row["dirty"] = tracked
                row["untracked"] = untracked

                if tracked > 0:
                    label = f"Modified ({tracked})"
                    if untracked > 0:
                        label += f" · {untracked} untracked"
                    row.update(state="modified", label=label)
                    dirty += 1
                elif untracked > 0:
                    names = [line[3:].strip() for line in untracked_lines[:3]]
                    detail = "untracked: " + ", ".join(names)
                    if untracked > len(names):
                        detail += " …"
                    row.update(
                        state="untracked",
                        label=f"Up to date · {untracked} untracked",
                        detail=detail,
                    )
                    untracked_count += 1
                else:
                    row.update(state="clean", label="Up to date")

        rows.append(row)

    parts = []
    if dirty:
        parts.append(f"{dirty} modified")
    if untracked_count:
        parts.append(f"{untracked_count} untracked")
    if missing:
        parts.append(f"{missing} missing")
    if errors:
        parts.append(f"{errors} errors")
    clean = len(repos) - dirty - untracked_count - missing - errors
    if clean > 0:
        parts.append(f"{clean} up to date")

    return {
        "ok": dirty == 0 and untracked_count == 0 and missing == 0 and errors == 0,
        "summary": " · ".join(parts) if parts else "No repositories",
        "dirtyCount": dirty,
        "untrackedCount": untracked_count,
        "missingCount": missing,
        "errorCount": errors,
        "rows": rows,
    }


def action_branches(workspace, repos):
    rows = []
    mismatched = missing = errors = 0
    for repo in repos:
        path = repo_path(workspace, repo["dest"])
        row = inspect_repo(path)
        row["dest"] = repo["dest"]
        row["expectedBranch"] = repo["branch"]
        row["eligible"] = False
        row["ineligibleReason"] = ""
        row["branches"] = []
        if row["state"] == "missing":
            missing += 1
            row["ineligibleReason"] = "repository unavailable"
        elif row["state"] == "error":
            errors += 1
            row["ineligibleReason"] = "repository unavailable"
        else:
            clean, reason = working_tree_clean(path)
            row["eligible"] = clean
            if not clean:
                row["ineligibleReason"] = reason
            row["branches"] = all_branches(path)

            # Гарантируем, что текущая ветка записана в row["branch"]
            if not row.get("branch"):
                code, out, _ = run_git(path, ["symbolic-ref", "--short", "-q", "HEAD"])
                row["branch"] = out.strip() if code == 0 else "detached"

            if row["branch"] != repo["branch"]:
                row.update(
                    state="mismatch",
                    label=row["branch"],
                    detail="expected {}".format(repo["branch"]),
                )
                mismatched += 1
            else:
                row.update(state="ok", label=row["branch"])
        rows.append(row)

    parts = []
    if mismatched:
        parts.append(f"{mismatched} on unexpected branch")
    if missing:
        parts.append(f"{missing} missing")
    if errors:
        parts.append(f"{errors} errors")
    ok = len(repos) - mismatched - missing - errors
    if ok > 0:
        parts.append(f"{ok} on expected branch")
    return {
        "ok": mismatched == 0 and missing == 0 and errors == 0,
        "summary": " · ".join(parts) if parts else "No repositories",
        "mismatchCount": mismatched,
        "missingCount": missing,
        "errorCount": errors,
        "rows": rows,
    }

def switch_branch_error(workspace, repos, message):
    result = action_branches(workspace, repos)
    result["action"] = "switch-branch"
    result["error"] = message
    result["summary"] = ""
    return result


def action_switch_branch(workspace, repos, dest, branch, create):
    branch = (branch or "").strip()
    target = next((repo for repo in repos if repo["dest"] == dest), None)
    if target is None:
        return switch_branch_error(workspace, repos, "repository not found: " + dest)
    if not branch:
        return switch_branch_error(workspace, repos, "branch name is required")

    path = repo_path(workspace, dest)
    row = inspect_repo(path)
    if row["state"] in ("missing", "error"):
        return switch_branch_error(workspace, repos, "repository unavailable: " + dest)

    clean, reason = working_tree_clean(path)
    if not clean:
        return switch_branch_error(
            workspace, repos, "repository is not clean: " + reason
        )

    code, _, _ = run_git(path, ["check-ref-format", "--branch", branch])
    if code != 0:
        return switch_branch_error(workspace, repos, "invalid branch name: " + branch)

    code, _, err = run_git(
        path, ["show-ref", "--verify", "--quiet", "refs/heads/" + branch]
    )
    exists = code == 0
    if code not in (0, 1):
        return switch_branch_error(
            workspace, repos, "could not check branch: " + (err or "git show-ref failed")
        )

    if create:
        if exists:
            return switch_branch_error(
                workspace, repos, "branch already exists: " + branch
            )
        code, _, err = run_git(path, ["switch", "-c", branch])
        if code != 0:
            code, _, err = run_git(path, ["checkout", "-b", branch])
        if code != 0:
            return switch_branch_error(
                workspace, repos, err or "could not create branch"
            )
        notice = f"Created {branch} in {dest}"
    else:
        # 1. Проверяем, существует ли ветка локально
        code_local, _, _ = run_git(path, ["show-ref", "--verify", "--quiet", "refs/heads/" + branch])

        if code_local == 0:
            # Локальная ветка есть — переключаемся стандартно
            code, _, err = run_git(path, ["switch", branch])
            if code != 0:
                code, _, err = run_git(path, ["checkout", branch])
        else:
            # 2. Локальной ветки нет. Проверяем, есть ли она на origin
            code_remote, _, _ = run_git(path, ["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + branch])

            if code_remote == 0:
                # Ветка есть на origin — создаем локальную с явным трекингом удаленной
                code, _, err = run_git(path, ["switch", "-c", branch, "--track", "origin/" + branch])
                if code != 0:
                    code, _, err = run_git(path, ["checkout", "-b", branch, "--track", "origin/" + branch])
            else:
                # 3. Ветки нет ни локально, ни на origin (например, она на другом remote)
                # Пробуем обычный switch/checkout — вдруг git сам разберется по своим механизмам
                code, _, err = run_git(path, ["switch", branch])
                if code != 0:
                    code, _, err = run_git(path, ["checkout", branch])

        if code != 0:
            return switch_branch_error(
                workspace, repos, err or "could not switch branch"
            )
        notice = f"Switched {dest} to {branch}"

    result = action_branches(workspace, repos)
    summary = notice
    if result.get("summary"):
        summary += " · " + result["summary"]
    result["action"] = "switch-branch"
    result["summary"] = summary
    result["dest"] = dest
    result["branch"] = branch
    return result


def action_fetch(workspace, repos, dest):
    target = next((repo for repo in repos if repo["dest"] == dest), None)
    if target is None:
        return {"ok": False, "error": "Repository not found"}
    path = repo_path(workspace, dest)
    code, out, err = run_git(path, ["fetch", "--all"], timeout=NETWORK_TIMEOUT)
    result = action_branches(workspace, repos)
    result["action"] = "branches"
    if code != 0:
        result["error"] = err or "git fetch failed"
    else:
        result["summary"] = "Fetched updates for " + dest
    return result


def pick_terminal(choice):
    # choice: "auto" или имя/путь терминала из настройки плагина
    choice = (choice or "").strip()
    if choice and choice != "auto":
        return shutil.which(choice)
    # $TERMINAL может указывать на xdg-terminal-exec — он не принимает
    # "--title ... -- cmd" и молча не запускает команду, поэтому он не в счёт
    env_terminal = os.environ.get("TERMINAL", "").strip()
    if env_terminal and "terminal-exec" in os.path.basename(env_terminal):
        env_terminal = ""
    order = ([env_terminal] if env_terminal else []) + list(TERMINAL_CANDIDATES)
    for name in order:
        found = shutil.which(name)
        if found:
            return found
    return None


def parse_size(spec, default=DEFAULT_DIFF_SIZE):
    # "1400x900" → (1400, 900); некорректное значение → default
    try:
        w, h = str(spec).lower().replace("*", "x").split("x")
        w, h = int(w), int(h)
        if 200 <= w <= 8000 and 100 <= h <= 5000:
            return (w, h)
    except (TypeError, ValueError):
        pass
    return default


def terminal_argv(terminal, title, shell_cmd, size=None):
    # --class/-a git-diff: окно помечается классом, под который Hyprland
    # заранее ставит rule (float/размер/центр) — окно появляется сразу
    # финального размера, и пейджер git (delta) рендерит корректно.
    if terminal.endswith("kitty"):
        argv = [terminal, "--class", DIFF_WINDOW_CLASS]
        if size:
            argv += ["--override", f"initial_window_width={size[0]}",
                     "--override", f"initial_window_height={size[1]}"]
        return argv + ["--title", title, "-e", "sh", "-c", shell_cmd]
    if terminal.endswith("alacritty"):
        return [terminal, "--title", title, "--class", DIFF_WINDOW_CLASS, "-e", "sh", "-c", shell_cmd]
    if terminal.endswith("xterm"):
        return [terminal, "-name", DIFF_WINDOW_CLASS, "-class", DIFF_WINDOW_CLASS,
                "-title", title, "-e", "sh", "-c", shell_cmd]
    if terminal.endswith("foot"):
        argv = [terminal, "--title", title, "-a", DIFF_WINDOW_CLASS]
        if size:
            # -w задаёт начальный размер в пикселях ещё до появления окна
            argv += ["-w", f"{size[0]}x{size[1]}"]
        return argv + ["--", "sh", "-c", shell_cmd]
    # прочие терминалы: разделитель "--" и команда с аргументами
    return [terminal, "--title", title, "--", "sh", "-c", shell_cmd]


def hypr_json(args):
    # Запрос JSON к Hyprland; None, если Hyprland недоступен
    hyprctl = shutil.which("hyprctl")
    if hyprctl is None or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    try:
        proc = subprocess.run([hyprctl] + args, capture_output=True,
                              text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return None


def clamp_size(size):
    # не выпускать окно за рабочую область текущего монитора
    monitors = hypr_json(["-j", "monitors"]) or []
    mon = next((m for m in monitors if m.get("focused")), None)
    if not mon:
        return size
    reserved = mon.get("reserved") or [0, 0, 0, 0]
    avail_w = int(mon.get("width", 0)) - int(reserved[0]) - int(reserved[2]) - 40
    avail_h = int(mon.get("height", 0)) - int(reserved[1]) - int(reserved[3]) - 40
    w, h = size
    return (max(400, min(w, avail_w)), max(200, min(h, avail_h)))


def hypr_float_rule(width, height):
    # Hyprland (Lua-API через hyprctl eval): оконное правило, по которому окна
    # класса git-diff становятся floating и центрируются УЖЕ при появлении,
    # до первого вывода git diff. Глобал в Lua-стейте хранит последний
    # применённый размер: при неизменном настройке правило не дублируется,
    # при смене размера регистрируется новое (Hyprland применяет последним
    # зарегистрированное подходящее правило).
    hyprctl = shutil.which("hyprctl")
    if hyprctl is None or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return False
    lua = (
        "_kai_git_diff_rules = _kai_git_diff_rules or {} "
        f'local key = "{width}x{height}" '
        "if _kai_git_diff_last ~= key then "
        f"_kai_git_diff_rules[key] = hl.window_rule({{match = {{class = '^{DIFF_WINDOW_CLASS}$'}}, "
        f"float = true, center = true, size = {{{width}, {height}}}}}) "
        "_kai_git_diff_last = key "
        "end"
    )
    try:
        proc = subprocess.run([hyprctl, "eval", lua], capture_output=True,
                              text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def float_hypr_window(title, width, height):
    # Запасной путь (если правило не зарегистрировалось): подгонка уже
    # созданного окна диспетчерами float/resize/center. Минус — терминал
    # сначала маппится в тайле, и вывод может перекосить.
    clients = hypr_json(["-j", "clients"]) or []
    addr = None
    for _ in range(40):  # окно появляется за ~200-400 мс, ждём до 4 с
        matches = [c for c in clients if (c.get("title") or "") == title]
        if matches:
            addr = matches[-1].get("address")
            break
        time.sleep(0.1)
        clients = hypr_json(["-j", "clients"]) or []
    if not addr:
        return False
    hyprctl = shutil.which("hyprctl")
    lua = (
        'local sel = "address:' + str(addr) + '" '
        "local a = hl.dispatch(hl.dsp.window.float({window = sel})) "
        f"local b = hl.dispatch(hl.dsp.window.resize({{window = sel, x = {width}, y = {height}}})) "
        "local c = hl.dispatch(hl.dsp.window.center({window = sel})) "
        'if not (a and a.ok and b and b.ok and c and c.ok) then error("hypr adjust failed") end'
    )
    try:
        proc = subprocess.run([hyprctl, "eval", lua], capture_output=True,
                              text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


def action_diff_term(workspace, repos, dest, terminal_choice, size_spec=""):
    result = {
        "action": "diff-term",
        "ok": False,
        "dest": dest,
        "spawned": False,
        "terminal": "",
        "reason": "",
        "summary": "",
        "error": None,
    }

    target = next((repo for repo in repos if repo["dest"] == dest), None)
    if target is None:
        result["error"] = "repository not found: " + dest
        return result

    path = repo_path(workspace, dest)
    row = inspect_repo(path)
    if row["state"] == "missing":
        result["error"] = "package directory not found: " + dest
        return result
    if row["state"] == "error":
        result["error"] = row["detail"] or "repository unavailable"
        return result

    code, out, _ = run_git(path, ["status", "--porcelain", "--untracked-files=normal"])
    if code != 0:
        result["error"] = "git status failed"
        return result
    lines = [line for line in out.splitlines() if line.strip()]
    if not lines:
        result["ok"] = True
        result["reason"] = "no uncommitted changes"
        result["summary"] = "No uncommitted changes in " + dest
        return result

    terminal = pick_terminal(terminal_choice)
    if terminal is None:
        result["error"] = "no terminal found (kitty/foot/alacritty/xterm)"
        return result
    result["terminal"] = terminal

    # Стандартный git diff: git сам запустит настроенный пейджер (git-delta),
    # так как stdout терминала — tty. git diff HEAD охватывает и индексированные
    # изменения. Для репозитория без коммитов HEAD нет — откат на git diff.
    path_q = shlex.quote(path)
    diff_cmd = f"git -C {path_q} diff HEAD || git -C {path_q} diff"
    has_tracked = any(not line.startswith("??") for line in lines)
    if has_tracked:
        shell_cmd = diff_cmd
    else:
        # только untracked файлы: diff пуст, показываем git status и держим окно
        shell_cmd = (
            f"git -C {path_q} status --short --branch; "
            "printf '\\nOnly untracked files:\\n'; "
            f"git -C {path_q} ls-files --others --exclude-standard; "
            "printf '\\nPress Enter to close...\\n'; read -r _ < /dev/tty"
        )

    title = f"git diff - {dest}"
    size = clamp_size(parse_size(size_spec) if size_spec else DEFAULT_DIFF_SIZE)
    # правило окон ставится до запуска терминала, чтобы окно появилось сразу
    # floating-ного размера и git diff/delta рендерились без перекосов
    ruled = hypr_float_rule(size[0], size[1])
    argv = terminal_argv(terminal, title, shell_cmd, size)
    try:
        subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        result["error"] = "could not launch terminal: " + str(exc)
        return result

    if ruled:
        result["floating"] = True
    else:
        result["floating"] = float_hypr_window(title, size[0], size[1])
    result["spawned"] = True
    result["ok"] = True
    result["summary"] = "Diff window for " + dest
    return result


def action_network(workspace, repos, action):
    rows = []
    ok_count = failed = missing = 0

    for repo in repos:
        path = repo_path(workspace, repo["dest"])
        row = inspect_repo(path)
        row["dest"] = repo["dest"]
        row["expectedBranch"] = repo["branch"]

        if row["state"] in ("missing", "error"):
            if row["state"] == "missing":
                missing += 1
            else:
                failed += 1
            row["state"] = "failed"
            rows.append(row)
            continue

        branch = row["branch"]
        if branch in ("", "(detached)"):
            row.update(
                state="failed",
                label="detached HEAD",
                detail="cannot determine current branch",
            )
            failed += 1
            rows.append(row)
            continue

        args = ["push", "origin", branch] if action == "push" else ["pull", "--no-edit", "origin", branch]
        code, out, err = run_git(path, args, timeout=NETWORK_TIMEOUT)
        if code == 0:
            row.update(state="ok", label=f"{branch} - Ok", detail=out)
            ok_count += 1
        else:
            row.update(
                state="failed",
                label=f"{branch} - Failed",
                detail=err or out or "git command failed",
            )
            failed += 1

        rows.append(row)

    parts = []
    if ok_count:
        parts.append(f"{ok_count} ok")
    if failed:
        parts.append(f"{failed} failed")
    if missing:
        parts.append(f"{missing} missing")

    return {
        "ok": failed == 0 and missing == 0,
        "summary": " · ".join(parts) if parts else "No repositories",
        "okCount": ok_count,
        "failedCount": failed,
        "missingCount": missing,
        "rows": rows,
    }


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    raw_workspace = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_WORKSPACE
    workspace = os.path.expandvars(os.path.expanduser(raw_workspace))

    result = {
        "action": action,
        "workspace": workspace,
        "configPath": os.path.join(workspace, "packages.json"),
        "ok": False,
        "error": None,
        "summary": "",
        "rows": [],
    }

    try:
        repos = read_repos(workspace)
    except FileNotFoundError:
        result["error"] = "packages.json not found"
        print(json.dumps(result))
        return 0
    except (OSError, ValueError) as exc:
        result["error"] = "invalid packages.json: " + str(exc)
        print(json.dumps(result))
        return 0

    if not repos:
        result["error"] = "packages.json has no repositories"
        print(json.dumps(result))
        return 0

    if action == "status":
        result.update(action_status(workspace, repos))
    elif action == "branches":
        result.update(action_branches(workspace, repos))
    elif action == "diff-term":
        if len(sys.argv) < 4:
            result["error"] = "usage: diff-term <workspace> <dest> [terminal] [WIDTHxHEIGHT]"
        else:
            terminal_choice = sys.argv[4] if len(sys.argv) > 4 else "auto"
            size_spec = sys.argv[5] if len(sys.argv) > 5 else ""
            result.update(action_diff_term(workspace, repos, sys.argv[3],
                                           terminal_choice, size_spec))
    elif action == "fetch":
        if len(sys.argv) < 4:
            result["error"] = "usage: fetch <workspace> <dest>"
        else:
            result.update(action_fetch(workspace, repos, sys.argv[3]))
    elif action == "switch-branch":
        if len(sys.argv) < 6:
            result["error"] = (
                "usage: switch-branch <workspace> <dest> <branch> <switch|create>"
            )
        elif sys.argv[5] not in ("switch", "create"):
            result["error"] = "invalid mode: " + sys.argv[5]
        else:
            result.update(
                action_switch_branch(
                    workspace,
                    repos,
                    sys.argv[3],
                    sys.argv[4],
                    sys.argv[5] == "create",
                )
            )
    elif action in ("pull", "push"):
        result.update(action_network(workspace, repos, action))
    else:
        result["error"] = "unknown action: " + action

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
