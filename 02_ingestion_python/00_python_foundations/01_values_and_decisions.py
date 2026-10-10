"""Variables, print, types, casting, and decisions."""

source_rows_text = "100000"
warehouse_rows_text = "99998"
source_amount_text = "250000.00"
warehouse_amount_text = "247500.00"

source_rows = int(source_rows_text)
warehouse_rows = int(warehouse_rows_text)
source_amount = float(source_amount_text)
warehouse_amount = float(warehouse_amount_text)
row_difference = warehouse_rows - source_rows
amount_difference = warehouse_amount - source_amount
amount_threshold = float("0.01")

print("Source rows:", source_rows, type(source_rows).__name__)
print("Warehouse rows:", warehouse_rows, type(warehouse_rows).__name__)
print("Row difference:", row_difference)
print("Amount difference:", amount_difference)

if row_difference == 0 and abs(amount_difference) < amount_threshold:
    status = "PASSED"
else:
    status = "FAILED — rows or posted amounts disagree"

print("Reconciliation:", status)
