CREATE procedure [run].[ProcessFinalise] @QueueID int, @status varchar(50),@ProcessAuditData nvarchar(2000) = '{}'
as
begin
      update [run].[ProcessQueue]
      set ProcessStatus=@status
            ,ProcessEndDate=getdate()
            ,ProcessAuditData = @ProcessAuditData
      where QueueID=@QueueID
end
GO
