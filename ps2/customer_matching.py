import csv
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path


# Common column names
COLUMN_ALIASES= {
    "id": "customer_id",
    "customerid": "customer_id",
    "customer_id": "customer_id",
    "full_name": "name",
    "customer_name": "name",
    "mobile": "phone",
    "mobile_number": "phone",
    "phone_number": "phone",
    "e_mail": "email",
    "email_address": "email",
}

MATCH_FIELDS= ["customer_id", "email", "phone", "name", "address", "city"]
STRONG_FIELDS = ["customer_id", "email", "phone"]
MISSING_VALUES= {"", "na", "n/a", "null", "none", "unknown", "-"}


def clean_column_name(name):
    name = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
    return COLUMN_ALIASES.get(name, name)


def clean_value(value):
    value= " ".join((value or "").strip().split())
    if value.lower() in MISSING_VALUES:
        return ""
    return value


def valid_email(value):
    return bool(re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", value))


def valid_phone(value):
    digits = normalise(value, "phone")
    allowed= bool(re.fullmatch(r"[0-9+() .-]+", value))
    return allowed and 7 <= len(digits) <= 15


def normalise(value, field):
    value = clean_value(value).lower()

    if field=="email":
        return value.replace(" ", "")
    if field == "phone":
        # Keep phone digits only
        return "".join(character for character in value if character.isdigit())
    if field in ("name", "address", "city"):
        return re.sub(r"[\W_]+", "", value)
    return value


def read_csv(file_name):
    rows=[]
    columns = []

    with open(file_name, "r", encoding="utf-8-sig", newline="") as file:
        reader= csv.DictReader(file)
        if not reader.fieldnames:
            raise ValueError(f"{file_name} does not have a header row")

        columns = [clean_column_name(column) for column in reader.fieldnames]
        if any(not column for column in columns):
            raise ValueError(f"{file_name} has an empty column name")
        if len(columns) != len(set(columns)):
            raise ValueError(f"{file_name} has duplicate or similar column names")

        for row_number, csv_row in enumerate(reader, start=2):
            if None in csv_row:
                raise ValueError(f"{file_name} has extra values in row {row_number}")
            row = {}
            for old_column, new_column in zip(reader.fieldnames, columns):
                row[new_column] = clean_value(csv_row.get(old_column, ""))
            rows.append(row)

    return rows, columns


def build_indexes(master_rows):
    indexes = {field: defaultdict(list) for field in MATCH_FIELDS}

    for position, row in enumerate(master_rows):
        for field in MATCH_FIELDS:
            value = normalise(row.get(field, ""), field)
            if value:
                indexes[field][value].append(position)

    return indexes


def find_candidate(incoming, indexes, master_rows):
    incoming_id = normalise(incoming.get("customer_id", ""), "customer_id")
    if incoming_id:
        id_matches = indexes["customer_id"].get(incoming_id, [])
        if len(id_matches)==1:
            return id_matches[0], "Matched using customer_id", False
        if len(id_matches) > 1:
            narrowed = narrow_candidates(id_matches, incoming, master_rows)
            if len(narrowed) == 1:
                return narrowed[0], "Matched using customer_id and other details", False
            return None, "The customer_id occurs more than once in the master file", True

    # Check email and phone
    evidence = []
    for field in ("email", "phone"):
        raw_value = incoming.get(field, "")
        is_valid = valid_email(raw_value) if field == "email" else valid_phone(raw_value)
        if raw_value and is_valid:
            value = normalise(raw_value, field)
            matches = set(indexes[field].get(value, []))
            if matches:
                evidence.append(matches)

    if evidence:
        strong_candidates = set.intersection(*evidence)
        if len(strong_candidates) == 1:
            position = next(iter(strong_candidates))
            return position, "Matched using email or phone", False
        if len(strong_candidates) > 1:
            narrowed = narrow_candidates(strong_candidates, incoming, master_rows)
            if len(narrowed) == 1:
                return narrowed[0], "Matched using contact and other details", False
            return None, "The contact value matches more than one master record", True
        return None, "Email and phone point to different master records", True

    # Check name with city or address
    name = normalise(incoming.get("name", ""), "name")
    name_matches = indexes["name"].get(name, []) if name else []
    supported = []

    for position in name_matches:
        master = master_rows[position]
        for field in ("city", "address"):
            left = normalise(incoming.get(field, ""), field)
            right = normalise(master.get(field, ""), field)
            if left and right and left == right:
                supported.append(position)
                break

    supported = sorted(set(supported))
    if len(supported) == 1:
        return supported[0], "Matched using name with city/address", False
    if len(supported) > 1:
        return None, "The available information does not identify one master record", True

    return None, "No reliable master record was found", False


def narrow_candidates(candidates, incoming, master_rows):
    narrowed = []

    for position in candidates:
        master = master_rows[position]
        matched = 0
        for field in ("email", "phone", "name", "address", "city"):
            left = normalise(incoming.get(field, ""), field)
            right = normalise(master.get(field, ""), field)
            if left and right and left == right:
                matched += 1
        if matched >= 1:
            narrowed.append(position)

    return narrowed


def find_irregular_information(row):
    irregular={}

    email = clean_value(row.get("email", ""))
    if email and not valid_email(email):
        irregular["email"] = "Email format appears invalid"

    phone = clean_value(row.get("phone", ""))
    if phone and not valid_phone(phone):
        irregular["phone"] = "Phone number must have 7 to 15 digits"

    return irregular


def classify_record(incoming, master_rows, indexes, all_columns):
    position, reason, ambiguous = find_candidate(incoming, indexes, master_rows)
    available = {key: value for key, value in incoming.items() if value}
    missing = [column for column in all_columns if not incoming.get(column, "")]
    conflicts = {}
    irregular = find_irregular_information(incoming)

    result = {
        "incoming_record": incoming,
        "available_information": available,
        "missing_information": missing,
        "irregular_information": irregular,
        "conflicting_information": conflicts,
        "matched_master_customer_id": None,
        "match_status": "",
        "reason": reason,
    }

    if position is not None:
        master = master_rows[position]
        result["matched_master_customer_id"] = master.get("customer_id") or position + 1

        # Compare the values
        for field in all_columns:
            incoming_value = incoming.get(field, "")
            master_value = master.get(field, "")
            if incoming_value and master_value:
                if normalise(incoming_value, field) != normalise(master_value, field):
                    conflicts[field] = {
                        "incoming_value": incoming_value,
                        "master_value": master_value,
                    }

        if conflicts:
            result["match_status"] = "conflicting_information"
            result["reason"] += ", but one or more values conflict"
        elif missing:
            result["match_status"] = "partial_match"
            result["reason"] += ", but the incoming record has missing values"
        else:
            result["match_status"] = "complete_match"
            result["reason"] += " and all available values agree"

    elif ambiguous:
        result["match_status"] = "incomplete_match"
    else:
        # Check for a new customer
        useful_fields = [field for field in MATCH_FIELDS if incoming.get(field, "")]
        has_new_strong_value = bool(incoming.get("customer_id", ""))
        has_new_strong_value = has_new_strong_value or valid_email(incoming.get("email", ""))
        has_new_strong_value = has_new_strong_value or valid_phone(incoming.get("phone", ""))

        if has_new_strong_value and len(useful_fields)>=2:
            result["match_status"] = "no_match_new_entity"
        else:
            result["match_status"] = "incomplete_match"
            result["reason"] = "Too little reliable information is available"

    return result


def save_outputs(results, incoming_columns, output_folder):
    output_folder.mkdir(parents=True, exist_ok=True)

    all_json_path = output_folder / "all_classified_records.json"
    special_json_path = output_folder / "special_records.json"
    summary_path = output_folder / "summary_statistics.json"
    csv_path = output_folder / "record_classification.csv"

    special_records = [
        result
        for result in results
        if result["match_status"] == "incomplete_match"
        or result["missing_information"]
        or result["irregular_information"]
        or result["conflicting_information"]
    ]
    summary= dict(Counter(result["match_status"] for result in results))
    for category in (
        "complete_match",
        "partial_match",
        "incomplete_match",
        "no_match_new_entity",
        "conflicting_information",
    ):
        summary.setdefault(category, 0)
    summary["total_incoming_records"] = len(results)

    with open(all_json_path, "w", encoding="utf-8") as file:
        json.dump(results, file, indent=4, ensure_ascii=False)
    with open(special_json_path, "w", encoding="utf-8") as file:
        json.dump(special_records, file, indent=4, ensure_ascii=False)
    with open(summary_path, "w", encoding="utf-8") as file:
        json.dump(summary, file, indent=4)

    headings = ["record_number", "match_status", "matched_master_customer_id", "reason"]
    headings += incoming_columns
    with open(csv_path, "w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=headings)
        writer.writeheader()
        for number, result in enumerate(results, start=1):
            row = {
                "record_number": number,
                "match_status": result["match_status"],
                "matched_master_customer_id": result["matched_master_customer_id"],
                "reason": result["reason"],
            }
            row.update(result["incoming_record"])
            writer.writerow(row)

    return summary


def main():
    master_file = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("customer master.csv")
    incoming_file = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("customer incoming.csv")
    output_folder = Path(sys.argv[3]) if len(sys.argv) > 3 else Path("question2_output")

    try:
        master_rows, master_columns = read_csv(master_file)
        incoming_rows, incoming_columns = read_csv(incoming_file)
    except (FileNotFoundError, ValueError) as error:
        print(f"Error: {error}")
        print("Place both supplied CSV files in this folder or pass their paths.")
        return 1

    if not master_rows:
        print("Error: The master CSV file has no customer records.")
        return 1

    common_match_fields = set(master_columns) & set(incoming_columns) & set(MATCH_FIELDS)
    if not common_match_fields:
        print("Error: The files do not share any usable matching columns.")
        return 1

    all_columns = list(dict.fromkeys(master_columns + incoming_columns))
    indexes = build_indexes(master_rows)
    results = [
        classify_record(row, master_rows, indexes, all_columns)
        for row in incoming_rows
    ]
    summary = save_outputs(results, incoming_columns, output_folder)

    print("\nClassification summary")
    print("----------------------")
    for category, count in summary.items():
        print(f"{category:28} {count}")
    print(f"\nOutput files were saved in: {output_folder.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
