-- 同步/文件业务用例不加载渲染引擎；视觉层另有 material_spec 和真实 KOReader 检查。
package.preload["inkbridge_material"] = function()
    return { widget = function(kind) return require("ui/widget/" .. kind) end }
end
