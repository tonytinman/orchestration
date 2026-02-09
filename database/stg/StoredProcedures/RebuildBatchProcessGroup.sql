CREATE PROC [stg].[RebuildBatchProcessGroup]
AS
BEGIN
    WITH SourceData AS (
        SELECT distinct
            b.BatchID, 
            pg.ProcessGroupID, 
            stg.Active
        FROM [stg].[Process] AS stg
        LEFT JOIN [config].[Batch] AS b ON b.BatchName = stg.BatchName
        LEFT JOIN [Config].[ProcessGroup] AS pg ON pg.ProcessGroupName = stg.ProcessGroupName
    )

    MERGE INTO Config.BatchProcessGroup AS Target
    USING SourceData AS Source
        ON Target.BatchID = Source.BatchID AND Target.ProcessGroupID = Source.ProcessGroupID

    WHEN MATCHED AND Target.Active <> Source.Active THEN
        UPDATE SET Active = Source.Active

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (BatchID, ProcessGroupID, Active)
        VALUES (Source.BatchID, Source.ProcessGroupID, Source.Active)

    WHEN NOT MATCHED BY SOURCE THEN
        DELETE

    OUTPUT
        inserted.BatchID AS Inserted_BatchID,
        inserted.ProcessGroupID AS Inserted_ProcessGroupID,
        inserted.Active AS Inserted_Active,
        deleted.BatchID AS Deleted_BatchID,
        deleted.ProcessGroupID AS Deleted_ProcessGroupID,
        deleted.Active AS Deleted_Active,
        GETDATE() AS ChangeTimestamp,
        $action AS ActionTaken
    INTO audit.BatchProcessGroup (
        Inserted_BatchID,
        Inserted_ProcessGroupID,
        Inserted_Active,
        Deleted_BatchID,
        Deleted_ProcessGroupID,
        Deleted_Active,
        ChangeTimestamp,
        ActionTaken
    );
END
GO

