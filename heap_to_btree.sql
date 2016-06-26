--edit your variables here, then run it
DECLARE 
	--the name of the table. casing is only important for creating a not-weird-looking clustered index name
	@table_name VARCHAR(1000) = 'MyTable'
	,@schema VARCHAR(100) = 'dbo'
	--if you dont want the procedure to actually run this statements, set this to 1 and the necessary statements will returned as a result set
	--you can then run the statements as necessary. The statements should be executed in order.
	,@show_statements_only BIT = 0;

--dont change anything after this line.
DECLARE @tsql VARCHAR(MAX);

IF @schema = 'sys'
BEGIN
	RAISERROR('Hey, you chose the "sys" schema, which suggests you''re trying to change a system table. Don''t do that.', 16, 1)
	RETURN
END

IF @show_statements_only = 1
BEGIN
	DECLARE @statements TABLE
	(
		statement_id INT IDENTITY(1,1) PRIMARY KEY CLUSTERED
		,statement VARCHAR(MAX)
	)
END

--check if we're actually looking at a heap
IF NOT EXISTS
(
	SELECT * 
	FROM sys.objects o
	JOIN sys.partitions p ON p.object_id = o.object_id
	WHERE o.name = @table_name AND p.index_id = 0
)
BEGIN
	RAISERROR('This table is not a heap!', 16, 1)
	RETURN
END

/*
GET PRIMARY KEY CONSTRAINT
*/
DECLARE 
	--the column name, or column names if multiple
	@primary_key_columns VARCHAR(1000)
	--the name of the constraint
	,@primary_key_name VARCHAR(1000);
SET @primary_key_columns = 
	SUBSTRING((
		SELECT ',' + COLUMN_NAME
		FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
		WHERE OBJECTPROPERTY(OBJECT_ID(CONSTRAINT_SCHEMA + '.' + CONSTRAINT_NAME), 'IsPrimaryKey') = 1
				AND TABLE_NAME = @table_name AND TABLE_SCHEMA = @schema
		ORDER BY ORDINAL_POSITION ASC
		FOR XML PATH('')), 2, 200000)

SET @primary_key_name = 
(
	SELECT TOP 1 CONSTRAINT_NAME
	FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE
	WHERE OBJECTPROPERTY(OBJECT_ID(CONSTRAINT_SCHEMA + '.' + CONSTRAINT_NAME), 'IsPrimaryKey') = 1
			AND TABLE_NAME = @table_name AND TABLE_SCHEMA = @schema
)

IF @primary_key_columns IS NULL OR @primary_key_columns = ''
BEGIN
	RAISERROR('Could not find a primary key column! A primary key must be set so we know with which column to create the clustered index.', 16, 1)
	RETURN
END
IF @primary_key_name IS NULL OR @primary_key_name = ''
BEGIN
	RAISERROR('Could not find a primary key constraint name! A primary key must be set so we know with which column to create the clustered index.', 16, 1)
	RETURN
END

/*
FOREIGN KEYS
*/
IF OBJECT_ID('tempdb..#foreign_keys') != null
	DROP TABLE #foreign_keys
SELECT
	fk.TABLE_NAME fk_table
	,cu.COLUMN_NAME fk_column
	,pt.COLUMN_NAME pk_column
	,c.CONSTRAINT_NAME constraint_name
	,trust.is_not_trusted
	,trust.is_not_for_replication
INTO #foreign_keys
FROM
	INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS c
		INNER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS fk ON c.CONSTRAINT_NAME = fk.CONSTRAINT_NAME
		INNER JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk ON c.UNIQUE_CONSTRAINT_NAME = pk.CONSTRAINT_NAME
		INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE cu ON c.CONSTRAINT_NAME = cu.CONSTRAINT_NAME
		INNER JOIN 
		(
			SELECT
				c1.TABLE_NAME,
				c2.COLUMN_NAME
			FROM
				INFORMATION_SCHEMA.TABLE_CONSTRAINTS c1
					INNER JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE c2 ON c1.CONSTRAINT_NAME = c2.CONSTRAINT_NAME
			WHERE
				c1.CONSTRAINT_TYPE = 'PRIMARY KEY'
		) pt ON pt.TABLE_NAME = pk.TABLE_NAME
		INNER JOIN
		(
			SELECT
				i.name
				,i.is_not_trusted
				,i.is_not_for_replication
			from sys.foreign_keys i
			INNER JOIN sys.objects o ON i.parent_object_id = o.object_id
			INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
		) trust ON trust.name = c.CONSTRAINT_NAME
WHERE
	pk.TABLE_NAME = @table_name

/*
NON-CLUSTERED INDEXES
*/
IF OBJECT_ID('tempdb..#nonclustered_indexes') != null
	DROP TABLE #nonclustered_indexes
SELECT 
	i.name index_name
	,i.fill_factor
	,i.filter_definition
	,c.name column_name
	,sc.index_column_id
	,sc.is_included_column
INTO #nonclustered_indexes
FROM sys.indexes i
	JOIN sys.columns c ON i.object_id = c.object_id
	JOIN sys.index_columns sc ON sc.object_id = i.object_id
		AND sc.index_id = i.index_id
		AND sc.column_id = c.column_id
WHERE 
	i.type_desc = 'NONCLUSTERED'
	AND i.is_primary_key = 0
	AND i.object_id = OBJECT_ID(@table_name)

/*
VARIABLES FOR CURSORS
*/
DECLARE 
	@fk_table VARCHAR(1000)
	,@fk_column VARCHAR(1000)
	,@pk_column VARCHAR(1000)
	,@constraint_name VARCHAR(1000)
	,@is_not_trusted BIT
	,@is_not_for_replication BIT
	,@index_fill_factor TINYINT
	,@index_name VARCHAR(1000)
	,@index_keys VARCHAR(MAX)
	,@index_includes VARCHAR(MAX)
	,@index_filter VARCHAR(MAX);

/*
START MAKING CHANGES
*/
BEGIN TRANSACTION
	--add a unique constraint to replace the primary key (temporary)
	SET @tsql = CONCAT('ALTER TABLE ', @schema, '.', @table_name, ' ADD CONSTRAINT UQTEMP_', @table_name, ' UNIQUE(', @primary_key_columns, ')');
	IF @show_statements_only = 0
		EXECUTE(@tsql)
	ELSE
		INSERT INTO @statements (statement) VALUES (@tsql)

	--drop all the current foreign key constraints attached to this table
	IF EXISTS(SELECT * FROM #foreign_keys)
	BEGIN
		DECLARE foreign_keys_cursor CURSOR
			FOR SELECT * FROM #foreign_keys
		OPEN foreign_keys_cursor
		FETCH NEXT FROM foreign_keys_cursor
		INTO @fk_table, @fk_column, @pk_column, @constraint_name, @is_not_trusted, @is_not_for_replication

		WHILE @@FETCH_STATUS = 0
		BEGIN
			SET @tsql = CONCAT('ALTER TABLE ', @fk_table, ' DROP CONSTRAINT ', @constraint_name);
			IF @show_statements_only = 0
				EXECUTE(@tsql)
			ELSE
				INSERT INTO @statements (statement) VALUES (@tsql)
		
			FETCH NEXT FROM foreign_keys_cursor
			INTO @fk_table, @fk_column, @pk_column, @constraint_name, @is_not_trusted, @is_not_for_replication
		END

		CLOSE foreign_keys_cursor
		DEALLOCATE foreign_keys_cursor
	END

	--drop the current primary key constraint
	SET @tsql = CONCAT('ALTER TABLE ', @schema, '.', @table_name, ' DROP CONSTRAINT ', @primary_key_name)
	IF @show_statements_only = 0
		EXECUTE(@tsql)
	ELSE
		INSERT INTO @statements (statement) VALUES (@tsql)

	--drop the non-clustered indexes
	IF EXISTS(SELECT * FROM #nonclustered_indexes)
	BEGIN
		DECLARE nonclustered_indexes_cursor CURSOR
			FOR SELECT index_name FROM #nonclustered_indexes
				GROUP BY index_name
		OPEN nonclustered_indexes_cursor
		FETCH NEXT FROM nonclustered_indexes_cursor
		INTO @index_name

		WHILE @@FETCH_STATUS = 0
		BEGIN
			SET @tsql = CONCAT('DROP INDEX ', @schema, '.', @table_name, '.', @index_name)
			IF @show_statements_only = 0
				EXECUTE(@tsql)
			ELSE
				INSERT INTO @statements (statement) VALUES (@tsql)

			FETCH NEXT FROM nonclustered_indexes_cursor
			INTO @index_name
		END

		CLOSE nonclustered_indexes_cursor
		DEALLOCATE nonclustered_indexes_cursor
	END

	--add the new clustered index
	SET @tsql = CONCAT('ALTER TABLE ', @schema, '.', @table_name, ' ADD CONSTRAINT PK_', @table_name, ' PRIMARY KEY CLUSTERED (', @primary_key_columns, ')')
	IF @show_statements_only = 0
		EXECUTE(@tsql)
	ELSE
		INSERT INTO @statements (statement) VALUES (@tsql)

	--drop the temporary unique constraint
	SET @tsql = CONCAT('ALTER TABLE ', @schema, '.', @table_name, ' DROP CONSTRAINT UQTEMP_', @table_name)
	IF @show_statements_only = 0
		EXECUTE(@tsql)
	ELSE
		INSERT INTO @statements (statement) VALUES (@tsql)

	--add the foreign key constraints back in
	IF EXISTS(SELECT * FROM #foreign_keys)
	BEGIN
		DECLARE foreign_keys_cursor CURSOR
			FOR SELECT * FROM #foreign_keys
		OPEN foreign_keys_cursor
		FETCH NEXT FROM foreign_keys_cursor
		INTO @fk_table, @fk_column, @pk_column, @constraint_name, @is_not_trusted, @is_not_for_replication

		WHILE @@FETCH_STATUS = 0
		BEGIN
			SET @tsql = CONCAT('ALTER TABLE ', @fk_table
				--determine if we need the WITH CHECK
				,CASE WHEN @is_not_trusted = 0 THEN ' WITH CHECK' ELSE ' ' END
				, ' ADD CONSTRAINT ', @constraint_name, ' FOREIGN KEY(', @fk_column, ') REFERENCES ', @table_name, '(', @pk_column, ')');
			IF @show_statements_only = 0
				EXECUTE(@tsql)
			ELSE
				INSERT INTO @statements (statement) VALUES (@tsql)
		
			FETCH NEXT FROM foreign_keys_cursor
			INTO @fk_table, @fk_column, @pk_column, @constraint_name, @is_not_trusted, @is_not_for_replication
		END

		CLOSE foreign_keys_cursor
		DEALLOCATE foreign_keys_cursor
	END

	--add the non-clustered indexes back in 
	IF EXISTS(SELECT * FROM #nonclustered_indexes)
	BEGIN
		DECLARE nonclustered_indexes_cursor CURSOR
			FOR SELECT index_name, fill_factor, filter_definition FROM #nonclustered_indexes
				GROUP BY index_name, fill_factor, filter_definition
		OPEN nonclustered_indexes_cursor
		FETCH NEXT FROM nonclustered_indexes_cursor
		INTO @index_name, @index_fill_factor, @index_filter

		WHILE @@FETCH_STATUS = 0
		BEGIN
			--get all the records for this index
			SET @index_keys = SUBSTRING((
				SELECT ',' + i.column_name
				FROM #nonclustered_indexes i
				WHERE i.index_name = @index_name
					AND i.is_included_column = 0
				ORDER BY i.index_column_id ASC
				FOR XML PATH('')), 2, 200000)

			SET @index_includes = SUBSTRING((
				SELECT ',' + i.column_name
				FROM #nonclustered_indexes i
				WHERE i.index_name = @index_name
					AND i.is_included_column = 1
				ORDER BY i.index_column_id ASC
				FOR XML PATH('')), 2, 200000)

			SET @tsql = CONCAT('CREATE INDEX ', @index_name, ' ON ', @schema, '.', @table_name, '(', @index_keys, ') ')
			IF @index_includes IS NOT NULL AND @index_includes != ''
				SET @tsql += CONCAT('INCLUDE (', @index_includes, ') ')
			IF @index_filter IS NOT NULL AND @index_filter != ''
				SET @tsql += CONCAT('WHERE ', @index_filter, ' ')
			IF @index_fill_factor IS NOT NULL AND @index_fill_factor != 0
				SET @tsql += CONCAT('WITH (FillFactor=', @index_fill_factor, ')')
			IF @show_statements_only = 0
				EXECUTE(@tsql)
			ELSE
				INSERT INTO @statements (statement) VALUES (@tsql)

			FETCH NEXT FROM nonclustered_indexes_cursor
			INTO @index_name, @index_fill_factor, @index_filter
		END

		CLOSE nonclustered_indexes_cursor
		DEALLOCATE nonclustered_indexes_cursor
	END
COMMIT TRANSACTION

DROP TABLE #foreign_keys
DROP TABLE #nonclustered_indexes

IF @show_statements_only = 1
	SELECT * FROM @statements
