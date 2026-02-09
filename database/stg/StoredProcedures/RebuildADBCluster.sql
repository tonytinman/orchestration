CREATE PROCEDURE [stg].[RebuildADBCluster]
    @Environment NVARCHAR(10) = 'dev'
AS

BEGIN
    -- Determine which cluster_id column to use based on environment
    DECLARE @ClusterIdColumn NVARCHAR(50)

    SET @ClusterIdColumn = CASE LOWER(@Environment)
        WHEN 'dev' THEN 'dev_cluster_id'
        WHEN 'ccd' THEN 'ccd_cluster_id'
        WHEN 'pre' THEN 'pre_cluster_id'
        WHEN 'prd' THEN 'prd_cluster_id'
        ELSE 'dev_cluster_id'  -- Default to dev if not recognized
    END

    -- Dynamic SQL to select the appropriate cluster_id based on environment
    DECLARE @SQL NVARCHAR(MAX)
    SET @SQL = N'
    WITH SourceData AS (
        SELECT
            ProcessGroupName,
            ' + @ClusterIdColumn + N' AS cluster_id
        FROM [stg].[ADBCluster]
    )

    MERGE INTO [config].[ADBCluster] AS Target
    USING SourceData AS Source
        ON Target.ProcessGroupName = Source.ProcessGroupName

    WHEN MATCHED AND Target.cluster_id <> Source.cluster_id THEN
        UPDATE SET cluster_id = Source.cluster_id

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ProcessGroupName, cluster_id)
        VALUES (Source.ProcessGroupName, Source.cluster_id)

    WHEN NOT MATCHED BY SOURCE THEN
        DELETE

    OUTPUT
        inserted.ProcessGroupName AS Inserted_ProcessGroupName,
        inserted.cluster_id AS Inserted_cluster_id,
        deleted.ProcessGroupName AS Deleted_ProcessGroupName,
        deleted.cluster_id AS Deleted_cluster_id,
        GETDATE() AS ChangeTimestamp,
        $action AS ActionTaken
    INTO [audit].[ADBCluster] (
        Inserted_ProcessGroupName,
        Inserted_cluster_id,
        Deleted_ProcessGroupName,
        Deleted_cluster_id,
        ChangeTimestamp,
        ActionTaken
    );'

    EXEC sp_executesql @SQL
END
GO
