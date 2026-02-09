CREATE PROC [stg].[RebuildBatch]
AS
BEGIN
    WITH SourceData AS (
        SELECT DISTINCT
            BatchName
        FROM [stg].[Process]
    )
-- Merge with audit logging
 MERGE INTO [Config].[Batch] AS Target
    USING SourceData AS Source
        ON Target.BatchName = Source.BatchName

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (BatchName)
        VALUES (Source.BatchName)

    WHEN NOT MATCHED BY SOURCE THEN 
        DELETE

    OUTPUT
        inserted.BatchID as [inserted_BatchID],
        inserted.BatchName as [inserted_BatchName],
        deleted.BatchID as [deleted_BatchID],
        deleted.BatchName as [deleted_BatchName],
        GETDATE() AS ChangeTimestamp,
        $action AS ActionTaken
    INTO [audit].[Batch]([inserted_BatchID], [inserted_BatchName], [deleted_BatchID], [deleted_BatchName], [ChangeTimestamp], [ActionTaken]);

END
GO

