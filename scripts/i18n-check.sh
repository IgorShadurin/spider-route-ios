#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_FILE="${2:-$PROJECT_ROOT/i18n-config.json}"
RELEASE_MODE="${3:-${I18N_REQUIRE_TRANSLATED:-0}}"
if [[ "${1:-}" == "--release" ]]; then PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CONFIG_FILE="$PROJECT_ROOT/i18n-config.json"; RELEASE_MODE=1; fi

python3 - "$PROJECT_ROOT" "$CONFIG_FILE" "$RELEASE_MODE" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(); config = json.loads(Path(sys.argv[2]).read_text()); release = str(sys.argv[3]).lower() in {"1","true","release","--release"}
bundle = root / "SpeedometerGPS"; required = set(config["required_locales"]); translated = set(config["translated_locales"]); staged = set(config["staged_locales"])
entry_re = re.compile(r'^"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";\s*$'); placeholder_re = re.compile(r'%%|%(?:\d+\$)?(?:[-+#0 ]*\d*(?:\.\d+)?)?[a-zA-Z@]')
source_re = re.compile(r'L10n\.(?:tr|format)\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"')
sys.path.insert(0,str(root/'scripts'))
from localization_script_guard import validate_values, copied_translation_issues
issues=[]; warnings=[]

def parse(path):
    result={}
    for number,line in enumerate(path.read_text(encoding="utf-8").splitlines(),1):
        text=line.strip()
        if not text or text.startswith("//"): continue
        match=entry_re.match(text)
        if not match: raise ValueError(f"Malformed strings entry: {path}:{number}")
        key,value=match.groups()
        if key in result: raise ValueError(f"Duplicate key {key}: {path}:{number}")
        result[key]=value
    return result

locale_dirs={p.name[:-6]:p for p in bundle.glob("*.lproj") if p.is_dir()}
issues += [f"Missing locale: {x}" for x in sorted(required-set(locale_dirs))]
issues += [f"Unexpected locale: {x}" for x in sorted(set(locale_dirs)-required)]
if translated | staged != required or translated & staged: issues.append("translated_locales and staged_locales must partition the required manifest")

source_keys=set()
for path in bundle.rglob("*.swift"):
    source_keys.update(key for key in source_re.findall(path.read_text(encoding="utf-8",errors="ignore")) if "\\(" not in key)
    source_keys.update(re.findall(r'"(rc_[a-z_]+)"', path.read_text(encoding="utf-8",errors="ignore")))

for table in ("Localizable.strings","InfoPlist.strings"):
    locale_values={}
    base_path=bundle/"en.lproj"/table
    if not base_path.exists(): issues.append(f"Missing base table {table}"); continue
    try: base=parse(base_path)
    except ValueError as error: issues.append(str(error)); continue
    expected=set(base) | (source_keys if table=="Localizable.strings" else set())
    for locale in sorted(required):
        path=bundle/f"{locale}.lproj"/table
        if not path.exists(): issues.append(f"{locale}: missing {table}"); continue
        try: values=parse(path)
        except ValueError as error: issues.append(str(error)); continue
        locale_values[locale]=values
        issues.extend(validate_values(locale,values))
        missing=expected-set(values); extra=set(values)-set(base)
        if missing: issues.append(f"{locale}/{table} missing: {', '.join(sorted(missing))}")
        if extra: issues.append(f"{locale}/{table} extra: {', '.join(sorted(extra))}")
        for key in set(base)&set(values):
            value=values[key]
            if not value.strip(): issues.append(f"{locale}/{table}: empty value for {key}")
            if sorted(placeholder_re.findall(value)) != sorted(placeholder_re.findall(base[key])): issues.append(f"{locale}/{table}: placeholder mismatch for {key}")
            limit=config.get("max_length_by_locale_key",{}).get(locale,{}).get(key,config.get("max_length_by_key",{}).get(key))
            if table=="Localizable.strings" and limit and len(value)>limit: issues.append(f"{locale}/{key}: {len(value)} exceeds {limit}")
            if table=="Localizable.strings" and locale in translated and not locale.startswith("en") and value==base[key] and value not in config.get("allowed_carryover_values",[]) and len(re.findall(r'[A-Za-z]+',value))>=2:
                issues.append(f"{locale}/{key}: probable English carryover")
    issues.extend(copied_translation_issues(locale_values))

if staged:
    message=f"{len(staged)} locale bundles are structurally complete but intentionally staged pending owner approval of English and Spanish"
    (issues if release else warnings).append(message)

report_dir=root/"artifacts/acceptance/localization"; report_dir.mkdir(parents=True,exist_ok=True)
report={"releaseMode":release,"requiredLocaleCount":len(required),"translatedLocales":sorted(translated),"stagedLocales":sorted(staged),"sourceKeyCount":len(source_keys),"failures":issues,"warnings":warnings}
(report_dir/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
(report_dir/"report.txt").write_text("\n".join([f"locales={len(required)} source_keys={len(source_keys)}"]+[f"WARNING: {x}" for x in warnings]+[f"ERROR: {x}" for x in issues])+"\n",encoding="utf-8")
print(f"[i18n] locales={len(required)} translated={len(translated)} staged={len(staged)} source_keys={len(source_keys)}")
for warning in warnings: print(f"warning: [i18n] {warning}")
for issue in issues: print(f"error: [i18n] {issue}")
if issues: print(f"FAIL: {len(issues)} localization issue(s)."); raise SystemExit(1)
print("PASS: locale manifest, key parity, placeholders, writing systems, copied-language blocks, syntax, and approved translation stages are valid.")
PY
