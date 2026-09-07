\copy region FROM 'region.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy nation FROM 'nation.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy part FROM 'part.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy supplier FROM 'supplier.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy partsupp FROM 'partsupp.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy customer FROM 'customer.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy orders FROM 'orders.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy lineitem FROM 'lineitem.tbl' WITH (FORMAT csv, DELIMITER '|');
