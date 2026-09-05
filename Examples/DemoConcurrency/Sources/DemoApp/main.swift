import ImagePipelineCore

let config = PipelineConfig()
let pipeline = ImagePipeline(config: config)

Task {
    let count = await pipeline.runAll(keys: ["a", "b", "c"])
    await pipeline.warmup()
    print("processed:", count)
}

let renderer = ThumbnailRenderer()
print(RenderService.renderSync(renderer))
RenderService.spawnWork()
