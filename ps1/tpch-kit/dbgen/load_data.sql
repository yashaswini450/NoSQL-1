\copy region FROM 'region.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy nation FROM 'nation.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy part FROM 'part.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy supplier FROM 'supplier.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy partsupp FROM 'partsupp.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy customer FROM 'customer.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy orders FROM 'orders.tbl' WITH (FORMAT csv, DELIMITER '|');
\copy lineitem FROM 'lineitem.tbl' WITH (FORMAT csv, DELIMITER '|');

ALTER TABLE region ADD PRIMARY KEY (r_regionkey);
ALTER TABLE nation ADD PRIMARY KEY (n_nationkey);
ALTER TABLE part ADD PRIMARY KEY (p_partkey);
ALTER TABLE supplier ADD PRIMARY KEY (s_suppkey);
ALTER TABLE partsupp ADD PRIMARY KEY (ps_partkey, ps_suppkey);
ALTER TABLE customer ADD PRIMARY KEY (c_custkey);
ALTER TABLE orders ADD PRIMARY KEY (o_orderkey);
ALTER TABLE lineitem ADD PRIMARY KEY (l_orderkey, l_linenumber);

CREATE INDEX ON partsupp (ps_suppkey);
CREATE INDEX ON lineitem (l_partkey);
CREATE INDEX ON lineitem (l_suppkey);
CREATE INDEX ON orders (o_custkey);
CREATE INDEX ON nation (n_regionkey);
CREATE INDEX ON supplier (s_nationkey);
CREATE INDEX ON customer (c_nationkey);

VACUUM ANALYZE;
