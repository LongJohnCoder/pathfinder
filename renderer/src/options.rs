// pathfinder/renderer/src/options.rs
//
// Copyright © 2019 The Pathfinder Project Developers.
//
// Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
// <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
// option. This file may not be copied, modified, or distributed
// except according to those terms.

//! Options that control how rendering is to be performed.

use crate::gpu_data::RenderCommand;
use pathfinder_geometry::basic::point::{Point2DF, Point3DF};
use pathfinder_geometry::basic::rect::RectF;
use pathfinder_geometry::basic::transform2d::Transform2DF;
use pathfinder_geometry::basic::transform3d::Perspective;
use pathfinder_geometry::clip::PolygonClipper3D;

pub trait RenderCommandListener: Send + Sync {
    fn send(&self, command: RenderCommand);
}

impl<F> RenderCommandListener for F
where
    F: Fn(RenderCommand) + Send + Sync,
{
    #[inline]
    fn send(&self, command: RenderCommand) {
        (*self)(command)
    }
}

#[derive(Clone, Default)]
pub struct RenderOptions {
    pub transform: RenderTransform,
    pub dilation: Point2DF,
    pub subpixel_aa_enabled: bool,
}

impl RenderOptions {
    pub(crate) fn prepare(self, bounds: RectF) -> PreparedRenderOptions {
        PreparedRenderOptions {
            transform: self.transform.prepare(bounds),
            dilation: self.dilation,
            subpixel_aa_enabled: self.subpixel_aa_enabled,
        }
    }
}

#[derive(Clone)]
pub enum RenderTransform {
    Transform2D(Transform2DF),
    Perspective(Perspective),
}

impl Default for RenderTransform {
    #[inline]
    fn default() -> RenderTransform {
        RenderTransform::Transform2D(Transform2DF::default())
    }
}

impl RenderTransform {
    fn prepare(&self, bounds: RectF) -> PreparedRenderTransform {
        let perspective = match self {
            RenderTransform::Transform2D(ref transform) => {
                if transform.is_identity() {
                    return PreparedRenderTransform::None;
                }
                return PreparedRenderTransform::Transform2D(*transform);
            }
            RenderTransform::Perspective(ref perspective) => *perspective,
        };

        let mut points = vec![
            bounds.origin().to_3d(),
            bounds.upper_right().to_3d(),
            bounds.lower_right().to_3d(),
            bounds.lower_left().to_3d(),
        ];
        debug!("-----");
        debug!("bounds={:?} ORIGINAL quad={:?}", bounds, points);
        for point in &mut points {
            *point = perspective.transform.transform_point(*point);
        }
        debug!("... PERSPECTIVE quad={:?}", points);

        // Compute depth.
        let quad = [
            points[0].perspective_divide(),
            points[1].perspective_divide(),
            points[2].perspective_divide(),
            points[3].perspective_divide(),
        ];
        debug!("... PERSPECTIVE-DIVIDED points = {:?}", quad);

        points = PolygonClipper3D::new(points).clip();
        debug!("... CLIPPED quad={:?}", points);
        for point in &mut points {
            *point = point.perspective_divide()
        }

        let inverse_transform = perspective.transform.inverse();
        let clip_polygon = points
            .into_iter()
            .map(|point| {
                inverse_transform
                    .transform_point(point)
                    .perspective_divide()
                    .to_2d()
            })
            .collect();
        return PreparedRenderTransform::Perspective {
            perspective,
            clip_polygon,
            quad,
        };
    }
}

pub(crate) struct PreparedRenderOptions {
    pub(crate) transform: PreparedRenderTransform,
    pub(crate) dilation: Point2DF,
    pub(crate) subpixel_aa_enabled: bool,
}

impl PreparedRenderOptions {
    #[inline]
    pub(crate) fn bounding_quad(&self) -> BoundingQuad {
        match self.transform {
            PreparedRenderTransform::Perspective { quad, .. } => quad,
            _ => [Point3DF::default(); 4],
        }
    }
}

pub(crate) type BoundingQuad = [Point3DF; 4];

pub(crate) enum PreparedRenderTransform {
    None,
    Transform2D(Transform2DF),
    Perspective {
        perspective: Perspective,
        clip_polygon: Vec<Point2DF>,
        quad: [Point3DF; 4],
    },
}

impl PreparedRenderTransform {
    #[inline]
    pub(crate) fn is_2d(&self) -> bool {
        match *self {
            PreparedRenderTransform::Transform2D(_) => true,
            _ => false,
        }
    }
}
