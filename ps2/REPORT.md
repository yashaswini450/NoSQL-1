# Question 2: Incomplete Data Integration and JSON Generation

## Aim

The aim is to compare every row in `customer incoming.csv` with the records in
`customer master.csv`. Each incoming row is placed in exactly one of these five
groups: complete match, partial match, incomplete match, no match/new entity, or
conflicting information.

## Matching criteria and justification

I used the following order because some customer details are more reliable than
others:

1. **Customer ID:** If it is present and occurs once in the master file, it is
   the strongest match.
2. **Email or phone:** If either value identifies exactly one master row, that
   row is selected. Spaces, letter case, and phone punctuation are ignored.
3. **Name with city or address:** A name by itself may not be unique, so it is
   accepted only when the same row also has the same city or address.
4. If different details point to different master rows, the record is called an
   incomplete match because the correct row is uncertain.
5. If no master is found, a record is called a new entity only when it has a new
   strong value (ID, email, or phone) and at least one more useful detail.
   Otherwise, it is called an incomplete match.

After selecting a master row, all values present in both records are compared.
Phone punctuation, extra spaces, capitalization, and simple punctuation in
names/addresses do not create false conflicts.

## Classification rules

- **Complete match:** A master row is identified, all compared values agree,
  and no expected value is missing from the incoming row.
- **Partial match:** A master row is identified and the available values agree,
  but one or more incoming values are missing.
- **Incomplete match:** The available details are too few or point to more than
  one possible master row.
- **No match/new entity:** No master row is found, but enough reliable details
  show that the row can be treated as a new customer.
- **Conflicting information:** A master row is identified, but at least one
  value present in both rows is different.

## How to run the program

Keep the Python file and the two supplied CSV files in the same folder. Run:

```bash
python customer_matching.py customer_master.csv customer_incoming.csv
```

To select a different output folder, add it as the third argument:

```bash
python customer_matching.py customer_master.csv customer_incoming.csv results
```

The program uses only built-in Python modules, so no package installation is
needed.

## Generated output

The program automatically processes every incoming record and creates:

- `record_classification.csv`: easy-to-read classification of every row.
- `all_classified_records.json`: complete details for every incoming row.
- `special_records.json`: rows with missing, irregular, or conflicting details.
- `summary_statistics.json`: the count in each of the five categories.

## Results from the supplied files

The master file contained 3,000 records. The incoming file contained 2,000
records. The program produced the following results:

| Category | Number of records |
|---|---:|
| Complete match | 400 |
| Partial match | 657 |
| Incomplete match | 193 |
| No match/new entity | 400 |
| Conflicting information | 350 |
| **Total** | **2,000** |

The program also generated 1,200 JSON documents for records that were
incomplete or contained missing, irregular, or conflicting information. No
invalid email or phone formats were detected in the supplied incoming file.

The JSON records contain available information, missing fields, irregular
information, conflicts, match status, matched customer ID, and the reason for
the decision.

## Why JSON is suitable

JSON is useful because incomplete records do not always contain the same fields.
One customer may be missing an email, while another may have a conflicting phone
number. JSON can store these different structures without forcing every record
to have exactly the same values. Lists can hold missing field names, and nested
objects can keep both the incoming and master values when there is a conflict.
It is also readable and supported by most programming languages and NoSQL
databases.

## Assumptions

- The first row of both CSV files contains column headings.
- IDs, emails, and phone numbers should normally identify one customer.
- Differences in case, spaces, or phone punctuation do not change identity.
- A matching ID is used to associate a row even if another value conflicts. The
  conflict is then reported instead of ignoring the record.
- Empty cells represent missing information.

## Limitations and difficulties

- Two different people can share a name, city, address, or even a phone number.
- The program does not perform advanced fuzzy spelling correction. For example,
  `John` and `Jon` are treated as different names.
- Old or shared email addresses and phone numbers can cause incorrect matches.
- The simple email and phone checks find obvious irregularities but do not prove
  that an email address or phone number is real.
- Classification depends on the stated rules. A different justified matching
  strategy may produce slightly different results.

## Evidence to include in the submission

After running the program, submit the Python source file, both input CSV files,
the four generated output files, and a screenshot or copied terminal output of
the summary. The team should check a sample of each category and be ready to
explain the matching rules during the demonstration.
