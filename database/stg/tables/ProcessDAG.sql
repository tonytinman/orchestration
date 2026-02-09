CREATE TABLE [stg].[ProcessDAG] (
    [ProcessName]            NVARCHAR (255) NOT NULL,
    [DependentOnProcessName] NVARCHAR (255) NULL,
    [DependencyType]         NVARCHAR (50)  NULL,
    [ProcessType]            NVARCHAR (50)  NULL,
    [DependentOnProcessType] NVARCHAR (50)  NULL
);
GO
