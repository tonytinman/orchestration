CREATE PROC [stg].[RebuildProcessGroup]
AS
BEGIN
    WITH SourceData AS (
        SELECT DISTINCT 
            [ProcessGroupName]
        FROM [stg].[Process]
        WHERE ProcessGroupName IS NOT NULL
    )

    MERGE INTO [Config].[ProcessGroup] AS Target
    USING SourceData AS Source
        ON Target.ProcessGroupName = Source.ProcessGroupName


    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ProcessGroupName)
        VALUES (Source.ProcessGroupName)

    WHEN NOT MATCHED BY SOURCE THEN
        DELETE

    OUTPUT
        inserted.ProcessGroupID AS Inserted_ProcessGroupID,
        inserted.ProcessGroupName AS Inserted_ProcessGroupName,
        deleted.ProcessGroupID AS Deleted_ProcessGroupID,
        deleted.ProcessGroupName AS Deleted_ProcessGroupName,
        GETDATE() AS ChangeTimestamp,
        $action AS ActionTaken
    INTO audit.ProcessGroup (
        Inserted_ProcessGroupID,
        Inserted_ProcessGroupName,
        Deleted_ProcessGroupID,
        Deleted_ProcessGroupName,
        ChangeTimestamp,
        ActionTaken
);
END
GO

