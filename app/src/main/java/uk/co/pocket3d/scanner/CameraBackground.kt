package uk.co.pocket3d.scanner

import android.opengl.GLES11Ext
import android.opengl.GLES20
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class CameraBackground {
    var textureId=-1; private var program=0
    private val quad=floatArrayOf(-1f,-1f,1f,-1f,-1f,1f,1f,1f)
    private fun buf(a:FloatArray):FloatBuffer=ByteBuffer.allocateDirect(a.size*4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply{put(a);position(0)}
    fun create(){
        val id=IntArray(1); GLES20.glGenTextures(1,id,0); textureId=id[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_MIN_FILTER,GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_MAG_FILTER,GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_WRAP_S,GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_WRAP_T,GLES20.GL_CLAMP_TO_EDGE)
        program=link("attribute vec2 p;attribute vec2 t;varying vec2 v;void main(){gl_Position=vec4(p,0.,1.);v=t;}",
            "#extension GL_OES_EGL_image_external : require\nprecision mediump float;varying vec2 v;uniform samplerExternalOES s;void main(){gl_FragColor=texture2D(s,v);}")
    }
    fun draw(frame:Frame){
        val tex=FloatArray(8)
        frame.transformCoordinates2d(Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,buf(quad),Coordinates2d.TEXTURE_NORMALIZED,buf(tex))
        GLES20.glDisable(GLES20.GL_DEPTH_TEST); GLES20.glUseProgram(program)
        val p=GLES20.glGetAttribLocation(program,"p"); val t=GLES20.glGetAttribLocation(program,"t")
        GLES20.glVertexAttribPointer(p,2,GLES20.GL_FLOAT,false,0,buf(quad)); GLES20.glEnableVertexAttribArray(p)
        GLES20.glVertexAttribPointer(t,2,GLES20.GL_FLOAT,false,0,buf(tex)); GLES20.glEnableVertexAttribArray(t)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0); GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,textureId)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4)
    }
    private fun link(v:String,f:String):Int{
        fun shader(type:Int,src:String)=GLES20.glCreateShader(type).also{GLES20.glShaderSource(it,src);GLES20.glCompileShader(it)}
        return GLES20.glCreateProgram().also{GLES20.glAttachShader(it,shader(GLES20.GL_VERTEX_SHADER,v));GLES20.glAttachShader(it,shader(GLES20.GL_FRAGMENT_SHADER,f));GLES20.glLinkProgram(it)}
    }
}
