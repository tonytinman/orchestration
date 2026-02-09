CREATE TABLE [stg].[Process] (
    [BatchName]        NVARCHAR (255) NOT NULL,
    [ProcessGroupName] NVARCHAR (255) NOT NULL,
    [ProcessName]      NVARCHAR (255) NOT NULL,
    [ProcessType]      NVARCHAR (255) NOT NULL,
    [ProcessSubType]   NVARCHAR (255) NOT NULL,
    [Contract]         NVARCHAR (500) NOT NULL,
    [NotebookName]     NVARCHAR (500) NULL,
    [Config]           NVARCHAR (MAX) NULL,
    [Active]           NVARCHAR (1)   NOT NULL,
    [Classification]   NVARCHAR (50)  NULL,
    [TargetTier]       NVARCHAR (50)  NOT NULL
);
GO
