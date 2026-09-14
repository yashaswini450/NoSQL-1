# Question 2: Incomplete Data Integration and JSON Generation

## Aim

The aim is to compare every row in `customer_incoming.csv` with the records in
`customer_master.csv`. Each incoming row is placed in exactly one of these five
groups: complete match, partial match, incomplete match, no match/new entity, or
conflicting information.

## Matching criteria and justification

I used the following order because some customer details are more reliable than
others:

1. **Customer ID:** If it is present and occurs once in the master file, it is
   the strongest match.
2. **Email or phone:** If either value identifies exactly one master row, that
   row is selected. Extra spaces, letter case, and phone punctuation are ignored.
3. **Name with city or address:** A name by itself may not be unique, so it is
   accepted only when the same row also has the same city or address.
4. If different details point to different master rows, the record is called an
   incomplete match because the correct row is uncertain.
5. If no master is found, a record is called a new entity only when it has a new
   strong value (ID, email, or phone) and at least one more useful detail.
   Otherwise, it is called an incomplete match.

After selecting a master row, all values present in both records are compared.
Phone punctuation, extra spaces, capitalization, and simple punctuation in
names and addresses do not create false conflicts.

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

To save the output in the `results` folder, run:

```bash
python customer_matching.py customer_master.csv customer_incoming.csv results
```

The program uses only built-in Python modules, so no package installation is
needed.

## Generated output

The program automatically processes every incoming record and creates:

- `record_classification.csv`: classification of every incoming row.
- `all_classified_records.json`: complete details for every incoming row.
- `special_records.json`: incomplete rows and rows with missing, irregular, or
  conflicting details.
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

The program generated 1,200 JSON documents for records that were incomplete or
contained missing, irregular, or conflicting information. No invalid email or
phone formats were detected in the supplied incoming file.

Each JSON record contains the available information, missing fields, irregular
information, conflicts, match status, matched customer ID, and reason for the
decision.

## Why JSON is suitable

JSON is useful because incomplete records do not always contain the same fields.
One customer may be missing an email, while another may have a conflicting phone
number. JSON can store these different structures without forcing every record
to contain the same values.

Lists can store missing field names. Nested objects can store both the incoming
and master values when there is a conflict. JSON is also readable and supported
by most programming languages and NoSQL databases.

## Assumptions

- The first row of both CSV files contains column headings.
- IDs, emails, and phone numbers should normally identify one customer.
- A name alone is not enough for a reliable match.
- Differences in case, spaces, or phone punctuation do not change identity.
- A matching ID is used to associate a row even if another value conflicts. The
  conflict is then reported instead of ignoring the record.
- Empty cells and markers such as `NA`, `N/A`, `null`, `none`, `unknown`, and
  `-` represent missing information.
- Repeated incoming identifiers are processed separately because every incoming
  row must be classified.

## Difficulties encountered

The main difficulties were:

- Matching records with missing customer IDs.
- Handling repeated names.
- Cleaning extra spaces and punctuation.
- Processing completely blank incoming records.
- Deciding whether a record was incomplete or represented a new customer.
- Handling cases where email and phone pointed to different master records.
- Preserving missing and conflicting information in JSON.

## Limitations

- Different people may share the same name, city, address, or phone number.
- The program does not perform advanced fuzzy spelling correction. For example,
  `John` and `Jon` are treated as different names.
- Old or shared email addresses and phone numbers can cause incorrect matches.
- The email and phone checks validate only basic format. They cannot prove that
  an email address or phone number is genuine.
- Classification depends on the stated rules. A different justified matching
  strategy may produce slightly different results.

## Verification

The solution was tested for complete matches, partial matches, conflicts,
incomplete records, new customers, duplicate identifiers, duplicate names,
invalid contact details, missing-value markers, Unicode names, extra CSV values,
and duplicate column names.

The final program processed all 2,000 incoming records successfully. Every
record was classified exactly once, and an independent audit found no errors.
