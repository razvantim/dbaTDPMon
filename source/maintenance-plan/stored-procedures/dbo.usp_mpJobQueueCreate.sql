RAISERROR('Create procedure: [dbo].[usp_mpJobQueueCreate]', 10, 1) WITH NOWAIT
GO
IF  EXISTS (
	    SELECT * 
	      FROM sys.objects 
	     WHERE object_id = OBJECT_ID(N'[dbo].[usp_mpJobQueueCreate]') 
	       AND type in (N'P', N'PC'))
DROP PROCEDURE [dbo].[usp_mpJobQueueCreate]
GO

CREATE PROCEDURE [dbo].[usp_mpJobQueueCreate]
		@projectCode			[varchar](32)=NULL,
		@module					[varchar](32)='maintenance-plan',
		@sqlServerNameFilter	[sysname]='%',
		@jobDescriptor			[varchar](256)='%',		/*	dbo.usp_mpDatabaseConsistencyCheck
															dbo.usp_mpDatabaseOptimize
															dbo.usp_mpDatabaseShrink
															dbo.usp_mpDatabaseBackup(Data)
															dbo.usp_mpDatabaseBackup(Log)
														*/
		@flgActions				[int] = 16383,			/*	   1	Weekly: Database Consistency Check - only once a week on Saturday
															   2	Daily: Allocation Consistency Check
															   4	Weekly: Tables Consistency Check - only once a week on Sunday
															   8	Weekly: Reference Consistency Check - only once a week on Sunday
															  16	Monthly: Perform Correction to Space Usage - on the first Saturday of the month
															  32	Daily: Rebuild Heap Tables - only for SQL versions +2K5
															  64	Daily: Rebuild or Reorganize Indexes
															 128	Daily: Update Statistics 
															 256	Weekly: Shrink Database (TRUNCATEONLY) - only once a week on Sunday
															 512	Monthly: Shrink Log File - on the first Saturday of the month 
															1024	Daily: Backup User Databases (diff) 
															2048	Weekly: User Databases (full) - only once a week on Saturday 
															4096	Weekly: System Databases (full) - only once a week on Saturday 
															8192	Hourly: Backup User Databases Transaction Log 
														*/
		@skipDatabasesList		[nvarchar](1024) = NULL,/* databases list, comma separated, to be excluded from maintenance */
	    @recreateMode			[bit] = 0,				/*  1 - existings jobs will be dropped an created based on this stored procedure logic
															0 - jobs definition will be preserved; only status columns will be updated; new jobs are created, for newly discovered databases
														*/
		@debugMode				[bit] = 0
/* WITH ENCRYPTION */
AS

-- ============================================================================
-- Copyright (c) 2004-2016 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 23.08.2016
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================
SET NOCOUNT ON

DECLARE   @codeDescriptor		[varchar](260)
		, @strMessage			[varchar](1024)
		, @projectID			[smallint]
		, @instanceID			[smallint]
		, @featureflgActions	[int]
		, @forInstanceID		[int]
		, @forSQLServerName		[sysname]

DECLARE		@serverEdition					[sysname],
			@serverVersionStr				[sysname],
			@serverVersionNum				[numeric](9,6)

DECLARE @jobExecutionQueue TABLE
		(
			[instance_id]			[smallint]		NOT NULL,
			[project_id]			[smallint]		NOT NULL,
			[module]				[varchar](32)	NOT NULL,
			[descriptor]			[varchar](256)	NOT NULL,
			[for_instance_id]		[smallint]		NOT NULL,
			[job_name]				[sysname]		NOT NULL,
			[job_step_name]			[sysname]		NOT NULL,
			[job_database_name]		[sysname]		NOT NULL,
			[job_command]			[nvarchar](max) NOT NULL
		)

------------------------------------------------------------------------------------------------------------------------------------------
--get default project code
IF @projectCode IS NULL
	SELECT	@projectCode = [value]
	FROM	[dbo].[appConfigurations]
	WHERE	[name] = 'Default project code'
			AND [module] = 'common'

SELECT @projectID = [id]
FROM [dbo].[catalogProjects]
WHERE [code] = @projectCode 

IF @projectID IS NULL
	begin
		SET @strMessage=N'ERROR: The value specifief for Project Code is not valid.'
		EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 1, @messagRootLevel = 0, @messageTreelevel = 1, @stopExecution=1
	end

------------------------------------------------------------------------------------------------------------------------------------------
SELECT @instanceID = [id]
FROM [dbo].[catalogInstanceNames]
WHERE [project_id] = @projectID
		AND [name] = @@SERVERNAME

------------------------------------------------------------------------------------------------------------------------------------------
DECLARE crsActiveInstances CURSOR LOCAL FAST_FORWARD FOR	SELECT	cin.[instance_id], cin.[instance_name]
															FROM	[dbo].[vw_catalogInstanceNames] cin
															WHERE 	cin.[project_id] = @projectID
																	AND cin.[instance_active]=1
																	AND cin.[instance_name] LIKE @sqlServerNameFilter
OPEN crsActiveInstances
FETCH NEXT FROM crsActiveInstances INTO @forInstanceID, @forSQLServerName
WHILE @@FETCH_STATUS=0
	begin
		SET @strMessage='--	Analyzing server: ' + @forSQLServerName
		RAISERROR(@strMessage, 10, 1) WITH NOWAIT

		--refresh current server information on internal metadata tables
		EXEC [dbo].[usp_refreshMachineCatalogs]	@projectCode	= @projectCode,
												@sqlServerName	= @forSQLServerName,
												@debugMode		= @debugMode


		--get destination server running version/edition
		SELECT @serverVersionNum = SUBSTRING([version], 1, CHARINDEX('.', [version])-1) + '.' + REPLACE(SUBSTRING([version], CHARINDEX('.', [version])+1, LEN([version])), '.', '')
		FROM	[dbo].[catalogInstanceNames]
		WHERE	[project_id] = @projectID
				AND [id] = @instanceID				

		DECLARE crsCollectorDescriptor CURSOR LOCAL FAST_FORWARD FOR	SELECT [descriptor]
																		FROM
																			(
																				SELECT 'dbo.usp_mpDatabaseConsistencyCheck' AS [descriptor] UNION ALL
																				SELECT 'dbo.usp_mpDatabaseOptimize' AS [descriptor] UNION ALL
																				SELECT 'dbo.usp_mpDatabaseShrink' AS [descriptor] UNION ALL
																				SELECT 'dbo.usp_mpDatabaseBackup(Data)' AS [descriptor] UNION ALL
																				SELECT 'dbo.usp_mpDatabaseBackup(Log)' AS [descriptor]
																			)X
																		WHERE (    [descriptor] LIKE @jobDescriptor
																				OR ISNULL(CHARINDEX([descriptor], @jobDescriptor), 0) <> 0
																				)			

		OPEN crsCollectorDescriptor
		FETCH NEXT FROM crsCollectorDescriptor INTO @codeDescriptor
		WHILE @@FETCH_STATUS=0
			begin
				SET @strMessage='Generating queue for : ' + @codeDescriptor
				EXEC [dbo].[usp_logPrintMessage] @customMessage = @strMessage, @raiseErrorAsPrint = 1, @messagRootLevel = 0, @messageTreelevel = 2, @stopExecution=0

				/* save the execution history */
				INSERT	INTO [dbo].[jobExecutionHistory]([instance_id], [project_id], [module], [descriptor], [filter], [for_instance_id], 
														 [job_name], [job_step_name], [job_database_name], [job_command], [execution_date], 
														 [running_time_sec], [log_message], [status], [event_date_utc])
						SELECT	[instance_id], [project_id], [module], [descriptor], [filter], [for_instance_id], 
								[job_name], [job_step_name], [job_database_name], [job_command], [execution_date], 
								[running_time_sec], [log_message], [status], [event_date_utc]
						FROM [dbo].[jobExecutionQueue] jeq
						WHERE [project_id] = @projectID
								AND [instance_id] = @instanceID
								AND [descriptor] = @codeDescriptor
								AND [for_instance_id] = @forInstanceID 
								AND [module] = @module
								AND [status] <> -1
								AND (   @skipDatabasesList IS NULL
									 OR (    @skipDatabasesList IS NOT NULL	
										 AND (
											  SELECT COUNT(*)
											  FROM [dbo].[ufn_getTableFromStringList](@skipDatabasesList, ',') X
											  WHERE jeq.[job_name] LIKE (DB_NAME() + ' - ' + @codeDescriptor + '%' + CASE WHEN @@SERVERNAME <> @@SERVERNAME THEN ' - ' + REPLACE(@@SERVERNAME, '\', '$') + ' ' ELSE ' - ' END + '%' + X.[value] + ']')
											) = 0
										)
									)

				IF @recreateMode = 1										
					DELETE jeq
					FROM [dbo].[jobExecutionQueue]  jeq
					WHERE [project_id] = @projectID
							AND [instance_id] = @instanceID
							AND [descriptor] = @codeDescriptor
							AND [for_instance_id] = @forInstanceID 
							AND [module] = @module
							AND (   @skipDatabasesList IS NULL
								 OR (    @skipDatabasesList IS NOT NULL	
									 AND (
										  SELECT COUNT(*)
										  FROM [dbo].[ufn_getTableFromStringList](@skipDatabasesList, ',') X
										  WHERE jeq.[job_name] LIKE (DB_NAME() + ' - ' + @codeDescriptor + '%' + CASE WHEN @@SERVERNAME <> @@SERVERNAME THEN ' - ' + REPLACE(@@SERVERNAME, '\', '$') + ' ' ELSE ' - ' END + '%' + X.[value] + ']')
										) = 0
									)
								)


				DELETE FROM @jobExecutionQueue

				------------------------------------------------------------------------------------------------------------------------------------------
				IF @codeDescriptor = 'dbo.usp_mpDatabaseConsistencyCheck'
					begin
						/*-------------------------------------------------------------------*/
						/* Weekly: Database Consistency Check - only once a week on Saturday */
						IF @flgActions & 1 = 1 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Database Consistency Check', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Database Consistency Check' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseConsistencyCheck] @sqlServerName	= ''' + @forSQLServerName + N''', @dbName	= ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 1, @flgOptions = 3, @maxDOP	= DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE', 'READ ONLY')
									)X

						/*-------------------------------------------------------------------*/
						/* Daily: Allocation Consistency Check */
						/* when running DBCC CHECKDB, skip running DBCC CHECKALLOC*/
						IF [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Database Consistency Check', GETDATE()) = 1
							SET @featureflgActions = 8
						ELSE
							SET @featureflgActions = 12

						IF @flgActions & 2 = 2 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Allocation Consistency Check', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Allocation Consistency Check' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseConsistencyCheck] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = ' + CAST(@featureflgActions AS [nvarchar]) + N', @flgOptions = DEFAULT, @maxDOP	= DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE', 'READ ONLY')
									)X

						/*-------------------------------------------------------------------*/
						/* Weekly: Tables Consistency Check - only once a week on Sunday*/
						IF @flgActions & 4 = 4 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Tables Consistency Check', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Tables Consistency Check' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseConsistencyCheck] @sqlServerName = ''' + @forSQLServerName + N''', @dbName	= ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 2, @flgOptions = DEFAULT, @maxDOP	= DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE', 'READ ONLY')
									)X

						/*-------------------------------------------------------------------*/
						/* Weekly: Reference Consistency Check - only once a week on Sunday*/
						IF @flgActions & 8 = 8 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Reference Consistency Check', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Reference Consistency Check' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseConsistencyCheck] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 16, @flgOptions = DEFAULT, @maxDOP	= DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE', 'READ ONLY')
									)X

						/*-------------------------------------------------------------------*/
						/* Monthly: Perform Correction to Space Usage - on the first Saturday of the month */
						IF @flgActions & 16 = 16 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseConsistencyCheck', 'Perform Correction to Space Usage', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Perform Correction to Space Usage' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseConsistencyCheck] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 64, @flgOptions = DEFAULT, @maxDOP	= DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X
					end


				------------------------------------------------------------------------------------------------------------------------------------------
				IF @codeDescriptor = 'dbo.usp_mpDatabaseOptimize'
					begin
						/*-------------------------------------------------------------------*/
						/* Daily: Rebuild Heap Tables - only for SQL versions +2K5*/
						IF @flgActions & 32 = 32 AND @serverVersionNum > 9 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseOptimize', 'Rebuild Heap Tables', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Rebuild Heap Tables' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseOptimize] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 16, @flgOptions = DEFAULT, @defragIndexThreshold = DEFAULT, @rebuildIndexThreshold = DEFAULT, @pageThreshold = DEFAULT, @rebuildIndexPageCountLimit = DEFAULT, @maxDOP = DEFAULT, @maxRunningTimeInMinutes = DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X

						/*-------------------------------------------------------------------*/
						/* Daily: Rebuild or Reorganize Indexes*/			
						IF @flgActions & 64 = 64 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseOptimize', 'Rebuild or Reorganize Indexes', GETDATE()) = 1
							begin
								SET @featureflgActions = 3
								
								IF @flgActions & 128 = 128 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseOptimize', 'Update Statistics', GETDATE()) = 1 /* Daily: Update Statistics */
									SET @featureflgActions = 11

								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Rebuild or Reorganize Indexes' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseOptimize] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = ' + CAST(@featureflgActions AS [varchar]) + ', @flgOptions = DEFAULT, @defragIndexThreshold = DEFAULT, @rebuildIndexThreshold = DEFAULT, @pageThreshold = DEFAULT, @rebuildIndexPageCountLimit = DEFAULT, @statsSamplePercent = DEFAULT, @statsAgeDays = DEFAULT, @statsChangePercent = DEFAULT, @maxDOP = DEFAULT, @maxRunningTimeInMinutes = DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X
							end

						/*-------------------------------------------------------------------*/
						/* Daily: Update Statistics */
						IF @flgActions & 128 = 128 AND NOT (@flgActions & 64 = 64) AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseOptimize', 'Update Statistics', GETDATE()) = 1
						BEGIN
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Update Statistics' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseOptimize] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @tableSchema = ''%'', @tableName = ''%'', @flgActions = 8, @flgOptions = DEFAULT, @statsSamplePercent = DEFAULT, @statsAgeDays = DEFAULT, @statsChangePercent = DEFAULT, @maxDOP = DEFAULT, @maxRunningTimeInMinutes = DEFAULT, @skipObjectsList = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X
						END
					end

				------------------------------------------------------------------------------------------------------------------------------------------
				IF @codeDescriptor = 'dbo.usp_mpDatabaseShrink'
					begin
						/*-------------------------------------------------------------------*/
						/* Weekly: Shrink Database (TRUNCATEONLY) - only once a week on Sunday*/
						IF @flgActions & 256 = 256 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseShrink', 'Shrink Database (TRUNCATEONLY)', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Shrink Database (TRUNCATEONLY)' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseShrink] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @flgActions = 2, @flgOptions = 1, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X

						/*-------------------------------------------------------------------*/
						/* Monthly: Shrink Log File - on the first Saturday of the month */
						IF @flgActions & 512 = 512 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseShrink', 'Shrink Log File', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Shrink Log File' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseShrink] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @flgActions = 1, @flgOptions = 0, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
												AND [state_desc] IN  ('ONLINE')
									)X

					end

				------------------------------------------------------------------------------------------------------------------------------------------
				IF @codeDescriptor = 'dbo.usp_mpDatabaseBackup(Data)'
					begin
						/*-------------------------------------------------------------------*/
						/* Daily: Backup User Databases (diff) */
						IF @flgActions & 1024 = 1024 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseBackup', 'User Databases (diff)', GETDATE()) = 1
							AND NOT (@flgActions & 2048 = 2048 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseBackup', 'User Databases (full)', GETDATE()) = 1)
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Backup User Databases (diff)' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseBackup] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @backupLocation = DEFAULT, @flgActions = 2, @flgOptions = DEFAULT, @retentionDays = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
									)X

						/*-------------------------------------------------------------------*/
						/* Weekly: User Databases (full) - only once a week on Saturday */
						IF @flgActions & 2048 = 2048 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseBackup', 'User Databases (full)', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Backup User Databases (full)' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseBackup] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @backupLocation = DEFAULT, @flgActions = 1, @flgOptions = DEFAULT, @retentionDays = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')														
									)X

						/*-------------------------------------------------------------------*/
						/* Weekly: System Databases (full) - only once a week on Saturday */
						IF @flgActions & 4096 = 4096 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseBackup', 'System Databases (full)', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Backup System Databases (full)' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseBackup] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @backupLocation = DEFAULT, @flgActions = 1, @flgOptions = DEFAULT, @retentionDays = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] IN ('master', 'model', 'msdb', 'distribution')														
									)X
					end

				------------------------------------------------------------------------------------------------------------------------------------------
				IF @codeDescriptor = 'dbo.usp_mpDatabaseBackup(Log)'
					begin
						/*-------------------------------------------------------------------*/
						/* Hourly: Backup User Databases Transaction Log */
						IF @flgActions & 8192 = 8192 AND [dbo].[ufn_mpCheckTaskSchedulerForDate](@projectCode, 'dbo.usp_mpDatabaseBackup', 'User Databases Transaction Log', GETDATE()) = 1
								INSERT INTO @jobExecutionQueue (  [instance_id], [project_id], [module], [descriptor]
																, [for_instance_id], [job_name], [job_step_name], [job_database_name]
																, [job_command])
								SELECT	@instanceID AS [instance_id], @projectID AS [project_id], @module AS [module], @codeDescriptor AS [descriptor],
										@forInstanceID AS [for_instance_id], 
										SUBSTRING(DB_NAME() + ' - ' + @codeDescriptor + ' - Backup User Databases (log)' + CASE WHEN @forSQLServerName <> @@SERVERNAME THEN ' - ' + REPLACE(@forSQLServerName, '\', '$') + ' ' ELSE ' - ' END + '[' + X.[database_name] + ']', 1, 128) AS [job_name],
										'Run'		AS [job_step_name],
										DB_NAME()	AS [job_database_name],
										'EXEC [dbo].[usp_mpDatabaseBackup] @sqlServerName = ''' + @forSQLServerName + N''', @dbName = ''' + X.[database_name] + N''', @backupLocation = DEFAULT, @flgActions = 4, @flgOptions = DEFAULT, @retentionDays = DEFAULT, @debugMode = ' + CAST(@debugMode AS [varchar])
								FROM
									(
										SELECT [name] AS [database_name]
										FROM [dbo].[catalogDatabaseNames]
										WHERE	[project_id] = @projectID
												AND [instance_id] = @forInstanceID
												AND [active] = 1
												AND [name] NOT IN ('master', 'model', 'msdb', 'tempdb', 'distribution')	
									)X
						end
				------------------------------------------------------------------------------------------------------------------------------------------

				IF @recreateMode = 0
					UPDATE jeq
						SET   jeq.[execution_date] = NULL
							, jeq.[running_time_sec] = NULL
							, jeq.[log_message] = NULL
							, jeq.[status] = -1
							, jeq.[event_date_utc] = GETUTCDATE()
					FROM [dbo].[jobExecutionQueue] jeq
					INNER JOIN @jobExecutionQueue S ON		jeq.[instance_id] = S.[instance_id]
														AND jeq.[project_id] = S.[project_id]
														AND jeq.[module] = S.[module]
														AND jeq.[descriptor] = S.[descriptor]
														AND jeq.[for_instance_id] = S.[for_instance_id]
														AND jeq.[job_name] = S.[job_name]
														AND jeq.[job_step_name] = S.[job_step_name]
														AND jeq.[job_database_name] = S.[job_database_name]
					WHERE (     @skipDatabasesList IS NULL
							OR (    @skipDatabasesList IS NOT NULL	
									AND (
										SELECT COUNT(*)
										FROM [dbo].[ufn_getTableFromStringList](@skipDatabasesList, ',') X
										WHERE S.[job_name] LIKE (DB_NAME() + ' - ' + S.[descriptor] + '%' + CASE WHEN @@SERVERNAME <> @@SERVERNAME THEN ' - ' + REPLACE(@@SERVERNAME, '\', '$') + ' ' ELSE ' - ' END + '%' + X.[value] + ']')
									) = 0
								)
						  )

				INSERT	INTO [dbo].[jobExecutionQueue](  [instance_id], [project_id], [module], [descriptor]
														, [for_instance_id], [job_name], [job_step_name], [job_database_name]
														, [job_command])
						SELECT	  S.[instance_id], S.[project_id], S.[module], S.[descriptor]
								, S.[for_instance_id], S.[job_name], S.[job_step_name], S.[job_database_name]
								, S.[job_command]
						FROM @jobExecutionQueue S
						LEFT JOIN [dbo].[jobExecutionQueue] jeq ON		jeq.[instance_id] = S.[instance_id]
																	AND jeq.[project_id] = S.[project_id]
																	AND jeq.[module] = S.[module]
																	AND jeq.[descriptor] = S.[descriptor]
																	AND jeq.[for_instance_id] = S.[for_instance_id]
																	AND jeq.[job_name] = S.[job_name]
																	AND jeq.[job_step_name] = S.[job_step_name]
																	AND jeq.[job_database_name] = S.[job_database_name]
						WHERE	jeq.[job_name] IS NULL
								AND (     @skipDatabasesList IS NULL
										OR (    @skipDatabasesList IS NOT NULL	
												AND (
													SELECT COUNT(*)
													FROM [dbo].[ufn_getTableFromStringList](@skipDatabasesList, ',') X
													WHERE S.[job_name] LIKE (DB_NAME() + ' - ' + S.[descriptor] + '%' + CASE WHEN @@SERVERNAME <> @@SERVERNAME THEN ' - ' + REPLACE(@@SERVERNAME, '\', '$') + ' ' ELSE ' - ' END + '%' + X.[value] + ']')
												) = 0
											)
									  )

				FETCH NEXT FROM crsCollectorDescriptor INTO @codeDescriptor
			end
		CLOSE crsCollectorDescriptor
		DEALLOCATE crsCollectorDescriptor
										

		FETCH NEXT FROM crsActiveInstances INTO @forInstanceID, @forSQLServerName
	end
CLOSE crsActiveInstances
DEALLOCATE crsActiveInstances
GO

