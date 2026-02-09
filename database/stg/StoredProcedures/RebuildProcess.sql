

CREATE   PROC [stg].[RebuildProcess]
AS
BEGIN
    SET NOCOUNT ON;

    ----------------------------------------------------------------------
    -- 1) Build source with ProcessGroupID and collapse accidental duplicates
    ----------------------------------------------------------------------
    ;WITH SourceBase AS (
        SELECT 
            pg.ProcessGroupID,
            p.BatchName,                -- informative; not merged into target
            p.ProcessGroupName,         -- informative; used only to find ProcessGroupID
            p.ProcessName,
            p.ProcessType,
            p.ProcessSubType,
            p.Contract,
            NULLIF(p.NotebookName, '')   AS NotebookName,
            p.Config,
            p.Active,
            NULLIF(p.Classification, '') AS Classification,
            NULLIF(p.TargetTier, '')     AS TargetTier
        FROM [stg].[Process] AS p
        LEFT JOIN [config].[ProcessGroup] AS pg
          ON pg.ProcessGroupName = p.ProcessGroupName
    ),
    -- If the CSV ever contains duplicate rows for the same (PGID, PN, PT), keep one
    SourceData AS (
        SELECT *
        FROM (
            SELECT
                sb.*,
                ROW_NUMBER() OVER (
                  PARTITION BY sb.ProcessGroupID, sb.ProcessName, sb.ProcessType
                  ORDER BY
                    CASE WHEN sb.Active = 1 THEN 0 ELSE 1 END,  -- prefer Active = 1
                    sb.NotebookName DESC,                       -- then prefer defined notebook
                    sb.Contract DESC                            -- then a defined contract
                ) AS rn
            FROM SourceBase AS sb
        ) x
        WHERE x.rn = 1
    )

    ----------------------------------------------------------------------
    -- 2) MERGE with disambiguated key (includes ProcessGroupID)
    ----------------------------------------------------------------------
    MERGE INTO Config.Process AS Target
    USING SourceData AS Source
      ON  ISNULL(Target.ProcessGroupID, -1) = ISNULL(Source.ProcessGroupID, -1)
      AND Target.ProcessName                = Source.ProcessName
      AND Target.ProcessType                = Source.ProcessType
      -- If ProcessSubType is part of identity, also add:
      -- AND ISNULL(Target.ProcessSubType,'') = ISNULL(Source.ProcessSubType,'')

    WHEN MATCHED AND (
           ISNULL(Target.Active, 0)             <> ISNULL(Source.Active, 0)
        OR ISNULL(Target.ProcessSubType, '')    <> ISNULL(Source.ProcessSubType, '')
        OR ISNULL(Target.Config, '')            <> ISNULL(Source.Config, '')
        OR ISNULL(Target.NotebookName, '')      <> ISNULL(Source.NotebookName, '')
        OR ISNULL(Target.Contract, '')          <> ISNULL(Source.Contract, '')
        OR ISNULL(Target.Classification, '')    <> ISNULL(Source.Classification, '')
        OR ISNULL(Target.TargetTier, '')        <> ISNULL(Source.TargetTier, '')   -- fixed: compare Target.TargetTier
    )
    THEN UPDATE SET
        Target.Active          = Source.Active,
        Target.NotebookName    = Source.NotebookName,
        Target.Contract        = Source.Contract,
        Target.ProcessSubType  = Source.ProcessSubType,
        Target.Config          = Source.Config,
        Target.Classification  = Source.Classification,
        Target.TargetTier      = Source.TargetTier,
        Target.ProcessGroupID  = Source.ProcessGroupID

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ProcessGroupID, ProcessName, ProcessType, ProcessSubType, Contract, NotebookName, Config, Active, Classification, TargetTier)
        VALUES (Source.ProcessGroupID, Source.ProcessName, Source.ProcessType, Source.ProcessSubType, Source.Contract, Source.NotebookName, Source.Config, Source.Active, Source.Classification, Source.TargetTier)

    -- Scope deletes to the groups present in this load to avoid unintended wipes
    WHEN NOT MATCHED BY SOURCE
         AND Target.ProcessGroupID IN (SELECT DISTINCT ProcessGroupID FROM SourceData)
    THEN DELETE

    OUTPUT
        inserted.ProcessID               AS Inserted_ProcessID,
        inserted.ProcessGroupID          AS Inserted_ProcessGroupID,
        inserted.ProcessName             AS Inserted_ProcessName,
        inserted.ProcessType             AS Inserted_ProcessType,
        inserted.ProcessSubType          AS Inserted_ProcessSubType,
        inserted.Contract                AS Inserted_Contract,
        inserted.NotebookName            AS Inserted_NotebookName,
        inserted.Config                  AS Inserted_Config,
        inserted.Active                  AS Inserted_Active,
        inserted.Classification          AS Inserted_Classification,
        inserted.TargetTier              AS Inserted_TargetTier,
        deleted.ProcessID                AS Deleted_ProcessID,
        deleted.ProcessGroupID           AS Deleted_ProcessGroupID,
        deleted.ProcessName              AS Deleted_ProcessName,
        deleted.ProcessType              AS Deleted_ProcessType,
        deleted.ProcessSubType           AS Deleted_ProcessSubType,
        deleted.Contract                 AS Deleted_Contract,
        deleted.NotebookName             AS Deleted_NotebookName,
        deleted.Config                   AS Deleted_Config,
        deleted.Active                   AS Deleted_Active,
        deleted.Classification           AS Deleted_Classification,
        deleted.TargetTier               AS Deleted_TargetTier,
        GETDATE()                        AS ChangeTimestamp,
        $action                          AS ActionTaken
    INTO audit.Process (
        Inserted_ProcessID,
        Inserted_ProcessGroupID,
        Inserted_ProcessName,
        Inserted_ProcessType,
        Inserted_ProcessSubType,
        Inserted_Contract,
        Inserted_NotebookName,
        Inserted_Config,
        Inserted_Active,
        Inserted_Classification,
        Inserted_TargetTier,
        Deleted_ProcessID,
        Deleted_ProcessGroupID,
        Deleted_ProcessName,
        Deleted_ProcessType,
        Deleted_ProcessSubType,
        Deleted_Contract,
        Deleted_NotebookName,
        Deleted_Config,
        Deleted_Active,
        Deleted_Classification,
        Deleted_TargetTier,
        ChangeTimestamp,
        ActionTaken
    );
END
GO

