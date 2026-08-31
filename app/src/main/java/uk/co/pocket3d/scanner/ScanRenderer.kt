package uk.co.pocket3d.scanner
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import com.google.ar.core.*
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
class ScanRenderer(private val activity:MainActivity,private val grid:VoxelGrid):GLSurfaceView.Renderer {
 private val background=CameraBackground(); @Volatile var session:Session?=null; @Volatile var scanning=false; private var lastSample=0L
 private var textureSession:Session?=null
 override fun onSurfaceCreated(gl:GL10?,config:EGLConfig?){GLES20.glClearColor(0f,0f,0f,1f);background.create()}
 override fun onSurfaceChanged(gl:GL10?,w:Int,h:Int){GLES20.glViewport(0,0,w,h);session?.setDisplayGeometry(activity.windowManager.defaultDisplay.rotation,w,h)}
 override fun onDrawFrame(gl:GL10?){GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);val s=session?:return;try{if(textureSession!==s){s.setCameraTextureName(background.textureId);textureSession=s};val frame=s.update();if(frame.timestamp!=0L)background.draw(frame);if(scanning&&frame.camera.trackingState==TrackingState.TRACKING&&System.currentTimeMillis()-lastSample>350){sample(frame);lastSample=System.currentTimeMillis()}}catch(_:Throwable){}}
 private fun sample(frame:Frame){try{frame.acquireDepthImage16Bits().use{image->val intr=frame.camera.imageIntrinsics;val dims=intr.imageDimensions;val sx=image.width.toFloat()/dims[0];val sy=image.height.toFloat()/dims[1];val f=intr.focalLength;val c=intr.principalPoint;val fx=f[0]*sx;val fy=f[1]*sy;val cx=c[0]*sx;val cy=c[1]*sy;val plane=image.planes[0];val b=plane.buffer.order(ByteOrder.LITTLE_ENDIAN);val pose=frame.camera.pose;for(v in 0 until image.height step 8)for(u in 0 until image.width step 8){val pos=v*plane.rowStride+u*plane.pixelStride;if(pos+1>=b.limit())continue;val mm=b.getShort(pos).toInt() and 0xffff;if(mm !in 120..2000)continue;val z=mm/1000f;val world=pose.transformPoint(floatArrayOf((u-cx)*z/fx,-(v-cy)*z/fy,-z));grid.add(world[0],world[1],world[2])}}}catch(_:Throwable){fallback(frame)};activity.runOnUiThread{activity.updateCount(grid.size)}}
 private fun fallback(frame:Frame){try{frame.acquirePointCloud().use{pc->val p=pc.points;while(p.remaining()>=4){val x=p.get();val y=p.get();val z=p.get();val confidence=p.get();if(confidence>.35f)grid.add(x,y,z)}}}catch(_:Throwable){}}
}
