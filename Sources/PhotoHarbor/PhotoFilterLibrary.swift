import Foundation

// XMP describes adjustment parameters; CUBE describes a color lookup table.
enum FilterLibraryKind: String, CaseIterable { case filter = "滤镜", lut = "LUT"
    var fileExtension: String { self == .filter ? "xmp" : "cube" }
    var formatDescription: String { self == .filter ? "XMP 调色预设" : "CUBE 3D LUT" }
}

struct ImportedPhotoFilter: Codable, Identifiable, Sendable {
    let id:String
    let name:String
    let warnings:[String]
}
struct ParsedPhotoFilter: Sendable { let recipe:PhotoAdjustments;let warnings:[String];let name:String? }

enum XMPPhotoFilter {
    static func parse(_ data:Data)throws->ParsedPhotoFilter {
        guard data.count<=2*1024*1024,let xml=String(data:data,encoding:.utf8),xml.range(of:"<!DOCTYPE",options:.caseInsensitive)==nil,xml.range(of:"<!ENTITY",options:.caseInsensitive)==nil else { throw LibraryError.message("XMP 无效、过大或包含不支持的 XML 实体。") }
        let reader=Reader(),parser=XMLParser(data:data);parser.delegate=reader;parser.shouldResolveExternalEntities=false
        guard parser.parse(),!reader.invalid else { throw LibraryError.message("无法解析 XMP 预设。") }
        var a=PhotoAdjustments(),warnings=[String](),mapped=Set<String>()
        func number(_ key:String)->Double? { guard let text=reader.fields[key],let value=Double(text),value.isFinite else { return nil };return value }
        func assign(_ key:String,_ apply:(Double)->Void) { if let value=number(key) { apply(value);mapped.insert(key) } }
        assign("Exposure2012"){a.exposure=min(5,max(-5,$0))};assign("Exposure"){a.exposure=min(5,max(-5,$0))}
        assign("Contrast2012"){a.contrast=1+min(100,max(-100,$0))/200}
        assign("Highlights2012"){a.highlights=min(2,max(0,1+$0/100))}
        assign("Shadows2012"){a.shadows=min(1,max(-1,$0/100))}
        assign("Blacks2012"){a.blackPoint=min(1,max(-1,-$0/100))}
        assign("Brightness"){a.brightness=min(1,max(-1,$0/100))}
        assign("Saturation"){a.saturation=min(2,max(0,1+$0/100))};assign("Vibrance"){a.vibrance=min(1,max(-1,$0/100))}
        assign("Clarity2012"){a.definition=min(1,max(0,$0/100));if $0<0 { warnings.append("负向清晰度尚未映射。") }}
        assign("Sharpness"){a.sharpness=min(1,max(0,$0/150))};assign("LuminanceSmoothing"){a.noiseReduction=min(1,max(0,$0/100))}
        assign("PostCropVignetteAmount"){a.vignette=min(1,max(-1,-$0/100))}
        if let temperature=number("Temperature"),temperature>1000 { a.temperature=min(1,max(-1,(temperature-6500)/2500));mapped.insert("Temperature");warnings.append("绝对色温按 sRGB 近似映射。") }
        assign("Tint"){a.tint=min(1,max(-1,$0/100))}
        if reader.fields["ConvertToGrayscale"]?.lowercased()=="true" { a.blackWhite=1;mapped.insert("ConvertToGrayscale") }
        for (field,channel) in [("ToneCurvePV2012",0),("ToneCurvePV2012Red",1),("ToneCurvePV2012Green",2),("ToneCurvePV2012Blue",3)] {
            guard let points=reader.curves[field],points.count>=2 else { continue }
            guard points.count<=256,points.allSatisfy({$0.x>=0 && $0.x<=1 && $0.y>=0 && $0.y<=1}),(1..<points.count).allSatisfy({points[$0].x>points[$0-1].x}) else { throw LibraryError.message("XMP 曲线控制点无效。") }
            let sampled=ChannelCurves.identity.map { CGPoint(x:$0.x,y:ChannelCurves.value($0.x,points:points)) }
            if channel==0 { a.curve=sampled } else { a.channelCurves[channel-1]=sampled }
            mapped.insert(field);if points.count != 5 { warnings.append("\(field) 已转换为五点曲线。") }
        }
        let colors=["Red","Yellow","Green","Aqua","Blue","Magenta"]
        for (index,color) in colors.enumerated() {
            assign("HueAdjustment"+color){a.selectiveColors[index].hue=min(1,max(-1,$0/100))}
            assign("SaturationAdjustment"+color){a.selectiveColors[index].saturation=min(1,max(-1,$0/100))}
            assign("LuminanceAdjustment"+color){a.selectiveColors[index].brightness=min(1,max(-1,$0/100))}
        }
        let metadata:Set<String>=["Version","ProcessVersion","PresetType","Name","Group","UUID","Cluster","ShortName","SortName","HasSettings","AlreadyApplied","Copyright","ContactInfo","URL","CameraModelRestriction","ToneCurveName2012","ToneCurveName","WhiteBalance"]
        for (key,value) in reader.fields.sorted(by:{$0.key<$1.key}) where !mapped.contains(key) && !metadata.contains(key) && !key.hasPrefix("Supports") {
            if value=="0" || value=="0.0" || value.lowercased()=="false" || value.isEmpty { continue }
            if key=="CameraProfile" { warnings.append("未应用 Adobe 配置文件：\(value)") }
            else { warnings.append("未映射：\(key)") }
        }
        guard !mapped.isEmpty else { throw LibraryError.message("这个 XMP 没有可用的基础调色参数；不支持只包含 Adobe 配置文件或局部蒙版的预设。") }
        warnings.insert("XMP 使用公开图像处理近似映射，效果可能与 Lightroom 不同。",at:0)
        return ParsedPhotoFilter(recipe:a,warnings:Array(Set(warnings)).sorted(),name:reader.fields["Name"])
    }
    private final class Reader:NSObject,XMLParserDelegate {
        var fields:[String:String]=[:],curves:[String:[CGPoint]]=[:],invalid=false
        var stack:[(String,String)]=[],prefixes:Set<String>=["crs"],count=0
        func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
            count+=1;if count>20000 || stack.count>48 { invalid=true;parser.abortParsing();return }
            for (key,value) in attributes where key.hasPrefix("xmlns:") && value=="http://ns.adobe.com/camera-raw-settings/1.0/" { prefixes.insert(String(key.dropFirst(6))) }
            for (key,value) in attributes { let parts=key.split(separator:":");if parts.count==2 && prefixes.contains(String(parts[0])) { fields[String(parts[1])]=value } }
            stack.append((elementName,""))
        }
        func parser(_ parser:XMLParser,foundCharacters string:String) { if !stack.isEmpty { stack[stack.count-1].1 += string } }
        func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {
            guard let current=stack.popLast() else{return};let text=current.1.trimmingCharacters(in:.whitespacesAndNewlines),parts=current.0.split(separator:":")
            if parts.count==2 && prefixes.contains(String(parts[0])) && !text.isEmpty { fields[String(parts[1])]=text }
            if current.0.hasSuffix(":li"),let field=stack.reversed().first(where:{$0.0.split(separator:":").first.map{prefixes.contains(String($0))} ?? false})?.0.split(separator:":").last.map(String.init) {
                if field.hasPrefix("ToneCurve") { let xy=text.split(separator:",").compactMap{Double($0.trimmingCharacters(in:.whitespaces))};if xy.count==2 && xy.allSatisfy(\.isFinite) { curves[field,default:[]].append(CGPoint(x:xy[0]/255,y:xy[1]/255)) } else { invalid=true } }
                if field=="Name" && !text.isEmpty { fields[field]=text }
            }
        }
        func parser(_ parser:XMLParser,resolveExternalEntityName name:String,systemID:String?)->Data? { nil }
    }
}

enum PhotoFilterStorage {
    static func file(_ entry:ImportedPhotoFilter,in directory:URL)->URL { directory.appendingPathComponent(entry.id+".xmp") }
    static func entries(in directory:URL)->[ImportedPhotoFilter] {
        guard (try? EditPersistence.rejectLinks(directory)) != nil,let files=try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) else{return []}
        return files.filter{$0.pathExtension=="json"}.compactMap { url in
            guard (try? EditPersistence.rejectLinks(url)) != nil,let data=try? Data(contentsOf:url),data.count<65536,let entry=try? JSONDecoder().decode(ImportedPhotoFilter.self,from:data),entry.id.count==64,entry.id.allSatisfy(\.isHexDigit),FileManager.default.fileExists(atPath:file(entry,in:directory).path) else{return nil};return entry
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    static func add(_ source:URL,to directory:URL,name:String)throws->ImportedPhotoFilter {
        guard source.pathExtension.lowercased()=="xmp",(try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 2*1024*1024 else{throw LibraryError.message("请选择不超过 2 MB 的 XMP 预设。")}
        let data=try Data(contentsOf:source),parsed=try XMPPhotoFilter.parse(data),id=EditPersistence.hash(data),display=try LUTStorage.normalizedName(name)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);try EditPersistence.rejectLinks(directory)
        if let existing=entries(in:directory).first(where:{$0.id==id}) { _ = try load(existing,in:directory);return existing }
        guard !entries(in:directory).contains(where:{$0.name.compare(display,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame}) else{throw LibraryError.message("已有同名 XMP 滤镜。")}
        let entry=ImportedPhotoFilter(id:id,name:display,warnings:parsed.warnings),target=file(entry,in:directory)
        if FileManager.default.fileExists(atPath:target.path) { try EditPersistence.rejectLinks(target);guard try Data(contentsOf:target)==data else{throw LibraryError.message("滤镜文件已变化。") } } else { try data.write(to:target,options:.withoutOverwriting) }
        try JSONEncoder().encode(entry).write(to:directory.appendingPathComponent(id+".json"),options:.withoutOverwriting);return entry
    }
    static func load(_ entry:ImportedPhotoFilter,in directory:URL)throws->PhotoAdjustments {
        let url=file(entry,in:directory);try EditPersistence.rejectLinks(url);let data=try Data(contentsOf:url)
        guard EditPersistence.hash(data)==entry.id else{throw LibraryError.message("XMP 滤镜校验失败。")};return try XMPPhotoFilter.parse(data).recipe
    }
    static func rename(_ entry:ImportedPhotoFilter,to name:String,in directory:URL)throws {
        let name=try LUTStorage.normalizedName(name);_ = try load(entry,in:directory)
        guard !entries(in:directory).contains(where:{$0.id != entry.id && $0.name.compare(name,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame}) else{throw LibraryError.message("已有同名 XMP 滤镜。")}
        let metadata=directory.appendingPathComponent(entry.id+".json");try EditPersistence.rejectLinks(metadata)
        try JSONEncoder().encode(ImportedPhotoFilter(id:entry.id,name:name,warnings:entry.warnings)).write(to:metadata,options:.atomic)
    }
}
