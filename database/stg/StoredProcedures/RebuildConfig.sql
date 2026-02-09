CREATE PROC [stg].[RebuildConfig]
    @Environment NVARCHAR(10) = 'dev'
AS
BEGIN
    EXEC [stg].[RebuildBatch]
    EXEC [stg].[RebuildProcessGroup]
    EXEC [stg].[RebuildBatchProcessGroup]
    EXEC [stg].[RebuildProcess]
    EXEC [stg].[RebuildProcessDAG]
    EXEC [stg].[RebuildADBCluster] @Environment = @Environment
END
GO
