CREATE PROCEDURE [stg].[RebuildProcessDAG]
AS

BEGIN
    WITH SourceData AS (
        SELECT 
            p.ProcessID AS ProcessID,
            dp.ProcessID AS DependentOnProcessID,
            NULLIF([stg].DependencyType, '') as DependencyType,
            p.Active,
            GETDATE() AS LastUpdated
        FROM [stg].[ProcessDAG] AS stg
        LEFT JOIN [config].[Process] AS p
            ON p.ProcessName = stg.ProcessName
            AND p.ProcessType = stg.ProcessType
        LEFT JOIN [config].[Process] AS dp
            ON dp.ProcessName = NULLIF(stg.DependentOnProcessName, '')
            AND dp.ProcessType = NULLIF(stg.DependentOnProcessType, '')
    )

MERGE INTO Config.ProcessDAG AS Target
USING SourceData AS Source
    ON Target.ProcessID = Source.ProcessID
    AND Target.DependentOnProcessID = Source.DependentOnProcessID

WHEN MATCHED AND Target.DependencyType <> Source.DependencyType THEN
    UPDATE SET DependencyType = Source.DependencyType, Active = Source.Active

WHEN NOT MATCHED BY TARGET THEN
    INSERT (ProcessID, DependentOnProcessID, DependencyType,Active,LastUpdated)
    VALUES (Source.ProcessID, Source.DependentOnProcessID, Source.DependencyType,Source.Active,GETDATE())

WHEN NOT MATCHED BY SOURCE THEN
    DELETE

OUTPUT
    inserted.ProcessID AS Inserted_ProcessID,
    inserted.DependentOnProcessID AS Inserted_DependentOnProcessID,
    inserted.DependencyType AS Inserted_DependencyType,
    inserted.Active AS Inserted_Active,
    deleted.ProcessID AS Deleted_ProcessID,
    deleted.DependentOnProcessID AS Deleted_DependentOnProcessID,
    deleted.DependencyType AS Deleted_DependencyType,
    deleted.Active AS Deleted_Active,
    GETDATE() AS ChangeTimestamp,
    $action AS ActionTaken
INTO audit.ProcessDAG (
    Inserted_ProcessID,
    Inserted_DependentOnProcessID,
    Inserted_DependencyType,
    Inserted_Active,
    Deleted_ProcessID,
    Deleted_DependentOnProcessID,
    Deleted_DependencyType,
    Deleted_Active,
    ChangeTimestamp,
    ActionTaken
);
END
GO

