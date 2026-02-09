

CREATE PROCEDURE [run].[InitiateBatch] (@LoadName varchar(100),@BatchName varchar(200),@PartitionDate varchar(100))
AS
BEGIN

DECLARE @LoadID uniqueidentifier = newid()

INSERT [run].[Load] ([LoadID],[BatchID],[LoadName],[PartitionDate],[LoadStart])
SELECT      @LoadID
            ,[BatchID]
            ,@LoadName
            ,@PartitionDate
            ,getdate()
FROM [Config].[Batch]
WHERE [BatchName]=@BatchName

INSERT [run].[LoadProcessGroup] ([LoadID],[BatchID],[ProcessGroupID],[Active])
SELECT      @LoadID
            ,b.[BatchID]
            ,pg.ProcessGroupID
            ,pg.Active
FROM [Config].[Batch] b
JOIN [Config].[BatchProcessGroup] pg ON pg.BatchID=b.BatchID
WHERE b.[BatchName]=@BatchName

SELECT @LoadID [LoadID]


END
GO

