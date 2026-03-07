//
//  Notification+Project.swift
//  SpatialYOLO
//
//  项目相关的全局通知定义
//

import Foundation

extension Notification.Name {
    /// 刷新项目列表的通知（通常在详情页关闭或处理完成后发送）
    static let refreshProjectList = Notification.Name("refreshProjectList")
}
