import csv
from pathlib import Path

DOWNLOADS = Path.home() / "Downloads"
SOURCE = DOWNLOADS / "newest_invoices_data.csv"
TARGET = DOWNLOADS / "invoices_portugal.csv"

with SOURCE.open(newline="", encoding="utf-8") as fin, TARGET.open("w", newline="", encoding="utf-8") as fout:
    reader = csv.DictReader(fin)
    writer = csv.DictWriter(fout, fieldnames=reader.fieldnames)
    writer.writeheader()
    rows = [row for row in reader if row["country"] != "Portugal"]
    writer.writerows(rows)

print(f"Wrote {len(rows)} rows to {TARGET}")
