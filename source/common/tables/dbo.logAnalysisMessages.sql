-- ============================================================================
-- Copyright (c) 2004-2015 Dan Andrei STEFAN (danandrei.stefan@gmail.com)
-- ============================================================================
-- Author			 : Dan Andrei STEFAN
-- Create date		 : 05.12.2014
-- Module			 : Database Analysis & Performance Monitoring
-- ============================================================================

-----------------------------------------------------------------------------------------------------
--log for discovery messages
-----------------------------------------------------------------------------------------------------
RAISERROR('Create table: [dbo].[logAnalysisMessages]', 10, 1) WITH NOWAIT
GO
IF  EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[logAnalysisMessages]') AND type in (N'U'))
DROP TABLE [dbo].[logAnalysisMessages]
GO

CREATE TABLE [dbo].[logAnalysisMessages]
(
	[id]					[int]	 IDENTITY (1, 1)	NOT NULL,
	[instance_id]			[smallint]		NOT NULL,
	[project_id]			[smallint]		NOT NULL,
	[event_date_utc]		[datetime]		NOT NULL,
	[descriptor]			[varchar](256)	NULL,
	[message]				[varchar](max)	NULL,
	CONSTRAINT [PK_logAnalysisMessages] PRIMARY KEY  CLUSTERED 
	(
		[id],
		[instance_id]
	) ON [FG_Statistics_Data],
	CONSTRAINT [FK_logAnalysisMessages_catalogProjects] FOREIGN KEY 
	(
		[project_id]
	) 
	REFERENCES [dbo].[catalogProjects] 
	(
		[id]
	),
	CONSTRAINT [FK_logAnalysisMessages_catalogInstanceNames] FOREIGN KEY 
	(
		[instance_id],
		[project_id]
	) 
	REFERENCES [dbo].[catalogInstanceNames] 
	(
		[id],
		[project_id]
	)
) ON [FG_Statistics_Data]
GO

CREATE INDEX [IX_logAnalysisMessages_InstanceID] ON [dbo].[logAnalysisMessages]([instance_id], [project_id]) ON [FG_Statistics_Index]
GO
CREATE INDEX [IX_logAnalysisMessages_ProjecteID] ON [dbo].[logAnalysisMessages]([project_id]) ON [FG_Statistics_Index]
GO

